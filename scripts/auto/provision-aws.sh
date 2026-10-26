#!/usr/bin/env bash
# =============================================================================
#  provision-aws.sh — (OPCIONAL) crea con AWS CLI lo que el manual hace con clics:
#     Paso 1 → 3 Security Groups + reglas      Paso 2 → 5 EC2 (con node.sh en user-data)
#     Paso 6 → RDS SQL Server Express
#  Ejecutar donde tengas AWS CLI con credenciales (AWS CloudShell, o tu PC con `aws configure`):
#     bash provision-aws.sh
#
#  Idempotente: si un SG/instancia/RDS ya existe lo reutiliza. No crea nada que ya esté.
#  Si tu evaluación exige hacerlo por consola web, NO uses este archivo: sigue el README
#  (Opción A) con las mismas reglas de SG, que son las correctas.
# =============================================================================
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
need_cmd aws
[ "${RDS_PASSWORD:-}" != "CAMBIA_ESTA_CLAVE" ] || die "Edita RDS_PASSWORD en config.env"
export AWS_DEFAULT_REGION="$AWS_REGION"
REPO_URL="${REPO_URL:-https://github.com/diegoECV/kubernetes.git}"; REPO_BRANCH="${REPO_BRANCH:-develop}"
RDS_INSTANCE_CLASS="${RDS_INSTANCE_CLASS:-db.t3.small}"

step "Cuenta y VPC"
aws sts get-caller-identity --query Arn --output text >/dev/null || die "AWS CLI sin credenciales."
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
[ "$VPC" != "None" ] || die "No hay Default VPC en $AWS_REGION."
ok "Default VPC: $VPC ($AWS_REGION)"

# ── Security Groups: primero VACÍOS, luego reglas (los grupos se referencian entre sí) ──
mk_sg() {  # mk_sg nombre descripción → imprime el id
  local id
  id=$(aws ec2 describe-security-groups --filters Name=group-name,Values="$1" Name=vpc-id,Values="$VPC" \
        --query 'SecurityGroups[0].GroupId' --output text)
  [ "$id" != "None" ] || id=$(aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC" --query GroupId --output text)
  echo "$id"
}
allow_cidr() {   # allow_cidr SG tcp 22 [22] 0.0.0.0/0
  aws ec2 authorize-security-group-ingress --group-id "$1" --protocol "$2" --port "$3" --cidr "$4" >/dev/null 2>&1 || true
}
allow_sg() {     # allow_sg SG_DESTINO SG_ORIGEN proto port|all
  local perm
  if [ "$4" = "all" ]; then perm="IpProtocol=-1,UserIdGroupPairs=[{GroupId=$2}]"
  else perm="IpProtocol=$3,FromPort=$4,ToPort=$4,UserIdGroupPairs=[{GroupId=$2}]"; fi
  aws ec2 authorize-security-group-ingress --group-id "$1" --ip-permissions "$perm" >/dev/null 2>&1 || true
}

step "Paso 1 — Security Groups"
SG_M=$(mk_sg visons-master-sg  "Security Group para visons-master control-plane")
SG_W=$(mk_sg visons-workers-sg "Security Group unificado para los 4 worker nodes de visons")
SG_R=$(mk_sg visons-rds-sg     "Security Group exclusivo para Amazon RDS SQL Server")
# MASTER
allow_cidr "$SG_M" tcp 22 0.0.0.0/0                 # SSH / EC2 Instance Connect
for p in 30080 30090 30500; do allow_cidr "$SG_M" tcp $p 0.0.0.0/0; done   # NodePorts: frontend, Spring, Flask
allow_sg   "$SG_M" "$SG_W" all all                  # workers → master: API 6443, join 8088, Flannel…
# WORKERS
allow_cidr "$SG_W" tcp 22 0.0.0.0/0
allow_sg   "$SG_W" "$SG_M" all all                  # master → workers: kubelet 10250 y pods (Flannel VXLAN 8472)
allow_sg   "$SG_W" "$SG_W" all all                  # worker ↔ worker: pods, DNS, MongoDB 27017
for p in 30080 30090 30500; do allow_cidr "$SG_W" tcp $p 0.0.0.0/0; done
# RDS
allow_sg   "$SG_R" "$SG_M" tcp 1433                 # sqlcmd desde el master
allow_sg   "$SG_R" "$SG_W" tcp 1433                 # R2DBC desde los backends
ok "SG master=$SG_M  workers=$SG_W  rds=$SG_R"

# ── EC2 ──────────────────────────────────────────────────────────────────────
step "Paso 2 — AMI Ubuntu 22.04 y EC2"
AMI=$(aws ec2 describe-images --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" "Name=state,Values=available" \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
ok "AMI: $AMI"

find_instance() {  # id si ya existe (no terminada)
  aws ec2 describe-instances --filters Name=tag:Name,Values="$1" Name=instance-state-name,Values=pending,running,stopped \
    --query 'Reservations[].Instances[].InstanceId | [0]' --output text
}
user_data() {   # user_data ROL [IP_MASTER] → imprime el script de arranque (embebe node.sh)
  echo '#!/bin/bash'
  echo 'exec >> /var/log/visons-userdata.log 2>&1'
  echo "cat > /opt/node.sh << 'NODE_EOF'"; cat "$AUTO_DIR/node.sh"; echo; echo 'NODE_EOF'
  if [ "$1" = "master" ]; then
    # El master además trae el repo y tu config.env para poder ejecutar deploy.sh sin copiar nada
    echo "apt-get update -qq && apt-get install -y -qq git"
    echo "sudo -u ubuntu git clone --branch '$REPO_BRANCH' '$REPO_URL' /home/ubuntu/kubernetes || true"
    echo "mkdir -p /home/ubuntu/kubernetes/scripts/auto"
    echo "cat > /home/ubuntu/kubernetes/scripts/auto/config.env << 'CFG_EOF'"; cat "${CONFIG_FILE:-$AUTO_DIR/config.env}"; echo; echo 'CFG_EOF'
    echo "chown -R ubuntu:ubuntu /home/ubuntu/kubernetes"
    echo "bash /opt/node.sh master"
  else
    echo "bash /opt/node.sh $1 $2"
  fi
}
launch() {  # launch NOMBRE ROL SG [IP_MASTER] → imprime instance-id
  local name="$1" role="$2" sg="$3" mip="${4:-}" id udf
  id=$(find_instance "$name")
  if [ "$id" != "None" ] && [ -n "$id" ]; then info "$name ya existe ($id)" >&2; echo "$id"; return; fi
  udf=$(mktemp); user_data "$role" "$mip" > "$udf"
  aws ec2 run-instances --image-id "$AMI" --instance-type "${INSTANCE_TYPE:-t3.medium}" --key-name "$KEY_NAME" \
    --security-group-ids "$sg" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name}]" \
    --user-data "file://$udf" --query 'Instances[0].InstanceId' --output text
  rm -f "$udf"
}
priv_ip() { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text; }
pub_ip()  { aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text; }

ID_M=$(launch visons-master master "$SG_M")
MASTER_PRIV=$(priv_ip "$ID_M"); ok "visons-master $ID_M  (IP privada $MASTER_PRIV)"
for r in frontend backend1 backend2 mongodb; do
  id=$(launch "visons-worker-$r" "$r" "$SG_W" "$MASTER_PRIV"); ok "visons-worker-$r $id"
done

# ── RDS ──────────────────────────────────────────────────────────────────────
step "Paso 6 — RDS SQL Server Express ($RDS_IDENTIFIER)"
if aws rds describe-db-instances --db-instance-identifier "$RDS_IDENTIFIER" >/dev/null 2>&1; then
  info "La RDS $RDS_IDENTIFIER ya existe."
else
  aws rds create-db-instance --db-instance-identifier "$RDS_IDENTIFIER" \
    --engine sqlserver-ex --license-model license-included --db-instance-class "$RDS_INSTANCE_CLASS" \
    --allocated-storage 20 --storage-type gp3 \
    --master-username "$RDS_USER" --master-user-password "$RDS_PASSWORD" \
    --vpc-security-group-ids "$SG_R" --no-publicly-accessible --backup-retention-period 0 >/dev/null
  ok "RDS en creación (tarda 10–20 min)"
fi
info "Esperando a que la RDS esté 'available'…"
aws rds wait db-instance-available --db-instance-identifier "$RDS_IDENTIFIER"
RDS_EP=$(aws rds describe-db-instances --db-instance-identifier "$RDS_IDENTIFIER" --query 'DBInstances[0].Endpoint.Address' --output text)
ok "RDS lista: $RDS_EP"

MPUB=$(pub_ip "$ID_M")
echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━ LISTO ━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Master (IP pública): $MPUB     Endpoint RDS: $RDS_EP"
echo "  Los nodos se instalan solos (≈10–15 min). Cuando estén listos:"
echo "     1) EC2 Instance Connect al master  →  tail -f /var/log/visons-userdata.log   (hasta ver 'Los 5 nodos están Ready')"
echo "     2) cd ~/kubernetes/scripts/auto && bash deploy.sh"

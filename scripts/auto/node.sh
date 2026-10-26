#!/usr/bin/env bash
# =============================================================================
#  node.sh — prepara UN nodo y lo deja unido al clúster (reemplaza Pasos 2.2, 3, 4 y 5)
# =============================================================================
#  USO (siempre con sudo, en EC2 Instance Connect):
#
#    Master:         sudo bash node.sh master
#    Workers:        sudo bash node.sh frontend  <IP_PRIVADA_DEL_MASTER>
#                    sudo bash node.sh backend1  <IP_PRIVADA_DEL_MASTER>
#                    sudo bash node.sh backend2  <IP_PRIVADA_DEL_MASTER>
#                    sudo bash node.sh mongodb   <IP_PRIVADA_DEL_MASTER>
#
#  El master imprime al final las 4 líneas de workers ya listas para copiar.
#  Es IDEMPOTENTE: si se corta o lo ejecutas dos veces, retoma donde se quedó.
#  Es AUTOCONTENIDO: no necesita config.env ni el repo clonado.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

ROLE="${1:-}"; MASTER_IP="${2:-}"
K8S_MINOR="v1.29"                      # versión de Kubernetes
FLANNEL_VERSION="v0.25.5"              # CNI (si falla la descarga usa 'latest')
POD_CIDR="10.244.0.0/16"               # red de pods que espera Flannel
JOIN_PORT=8088                         # puerto temporal donde el master publica el join
REPO_URL="${REPO_URL:-https://github.com/diegoECV/kubernetes.git}"
REPO_BRANCH="${REPO_BRANCH:-develop}"
NODE_SCRIPT_URL="${NODE_SCRIPT_URL:-https://raw.githubusercontent.com/diegoECV/kubernetes/develop/scripts/auto/node.sh}"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
step() { echo -e "\n${C}══ $* ══${N}"; }
ok()   { echo -e "${G}  ✅ $*${N}"; }
info() { echo -e "${Y}  ℹ  $*${N}"; }
die()  { echo -e "${R}  ❌ $*${N}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Ejecútalo con sudo."
case "$ROLE" in
  master) HOSTNAME_NEW="visons-master" ;;
  frontend|backend1|backend2|mongodb) HOSTNAME_NEW="visons-worker-$ROLE"
      [ -n "$MASTER_IP" ] || die "Falta la IP privada del master. Uso: sudo bash node.sh $ROLE <IP_PRIVADA_MASTER>" ;;
  *) die "Rol inválido '$ROLE'. Usa: master | frontend | backend1 | backend2 | mongodb" ;;
esac

imds() {  # metadata de EC2 con IMDSv2
  local t; t=$(curl -fsS -m 3 -X PUT http://169.254.169.254/latest/api/token \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 120" 2>/dev/null) || true
  curl -fsS -m 3 ${t:+-H "X-aws-ec2-metadata-token: $t"} "http://169.254.169.254/latest/$1"
}

# ─────────────────────────────────────────────────────────────────────────────
step "1/4 Hostname → $HOSTNAME_NEW"
# Para qué: Kubernetes usa el hostname como nombre del nodo. Debe ser fijo y único.
hostnamectl set-hostname "$HOSTNAME_NEW"
sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true
grep -q "$HOSTNAME_NEW" /etc/hosts || echo "127.0.1.1 $HOSTNAME_NEW" >> /etc/hosts
ok "hostname fijado"

# ─────────────────────────────────────────────────────────────────────────────
step "2/4 Preparación base (swap, kernel, containerd, kubeadm/kubelet/kubectl)"
# Para qué: kubelet se niega a arrancar con swap; los módulos y sysctl permiten que
# iptables vea el tráfico de los pods; containerd es el runtime de contenedores.
swapoff -a
sed -ri '/\sswap\s/s/^/#/' /etc/fstab        # comenta swap sin borrar otras líneas

printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
modprobe overlay; modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf << 'SYS'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYS
sysctl --system >/dev/null

if ! command -v kubeadm >/dev/null || ! systemctl is-active --quiet containerd; then
  apt-get update -qq
  apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release netcat-openbsd >/dev/null
  mkdir -p /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

  apt-get update -qq
  apt-get install -y -qq containerd.io kubelet kubeadm kubectl >/dev/null
  apt-mark hold kubelet kubeadm kubectl >/dev/null
fi
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml   # cgroups = systemd (obligatorio con kubelet)
systemctl enable --now containerd >/dev/null 2>&1
systemctl restart containerd
systemctl enable kubelet >/dev/null 2>&1
ok "swap off · containerd activo · $(kubeadm version -o short)"

# ─────────────────────────────────────────────────────────────────────────────
if [ "$ROLE" = "master" ]; then
  step "3/4 MASTER — kubeadm init + Flannel"
  PRIV=$(imds meta-data/local-ipv4); PUB=$(imds meta-data/public-ipv4 || true)
  info "IP privada: $PRIV | IP pública: ${PUB:-ninguna}"
  export KUBECONFIG=/etc/kubernetes/admin.conf

  if [ ! -f /etc/kubernetes/admin.conf ]; then
    # --apiserver-advertise-address: los workers hablan con la IP PRIVADA (estable aunque cambie la pública)
    # --apiserver-cert-extra-sans:   permite kubectl desde fuera con la IP pública
    kubeadm init --pod-network-cidr="$POD_CIDR" \
      --apiserver-advertise-address="$PRIV" \
      ${PUB:+--apiserver-cert-extra-sans="$PUB"} \
      --node-name="$HOSTNAME_NEW"
  else
    info "El clúster ya estaba inicializado, se reutiliza."
  fi

  # kubectl para el usuario que ejecutó sudo (ubuntu)
  U="${SUDO_USER:-ubuntu}"; H=$(getent passwd "$U" | cut -d: -f6)
  mkdir -p "$H/.kube"; cp -f /etc/kubernetes/admin.conf "$H/.kube/config"; chown -R "$U:$U" "$H/.kube"
  # Deja el repo (con estos scripts y los manifiestos) listo en el master para deploy.sh
  [ -d "$H/kubernetes/k8s" ] || sudo -u "$U" git clone --branch "$REPO_BRANCH" "$REPO_URL" "$H/kubernetes" \
    || info "No pude clonar el repo ahora; deploy.sh lo intentará de nuevo."

  kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" \
    || kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
  for i in $(seq 1 60); do
    kubectl get node "$HOSTNAME_NEW" --no-headers 2>/dev/null | grep -q ' Ready' && break; sleep 5
  done
  kubectl get nodes

  step "4/4 MASTER — publicar el 'kubeadm join' para los workers (solo dentro de la VPC)"
  # El token y el hash se generan aquí y los workers los leen solos: nadie copia nada.
  PUBDIR=/var/lib/visons/pub; mkdir -p "$PUBDIR"
  { echo '#!/usr/bin/env bash'; kubeadm token create --ttl 2h --print-join-command; } > "$PUBDIR/join.sh"
  pkill -f "http.server $JOIN_PORT" 2>/dev/null || true
  # Servidor temporal: escucha SOLO en la IP privada, máx. 2 h. El Security Group del
  # master ya permite todo el tráfico desde visons-workers-sg, así que solo los workers llegan.
  setsid nohup timeout 7200 python3 -m http.server "$JOIN_PORT" --bind "$PRIV" --directory "$PUBDIR" \
      >/var/log/visons-join.log 2>&1 < /dev/null &
  sleep 1
  curl -fsS "http://$PRIV:$JOIN_PORT/join.sh" >/dev/null && ok "join publicado en http://$PRIV:$JOIN_PORT/join.sh"

  echo -e "\n${G}━━━━━━━━ COPIA Y PEGA UNA LÍNEA EN CADA WORKER (EC2 Instance Connect) ━━━━━━━━${N}"
  for r in frontend backend1 backend2 mongodb; do
    echo "curl -fsSL $NODE_SCRIPT_URL | sudo bash -s -- $r $PRIV"
  done
  echo -e "${G}━━━━━ (si ya tienes node.sh en el worker:  sudo bash node.sh <rol> $PRIV) ━━━━━${N}\n"

  info "Esperando a que se unan los 4 workers (máx. 25 min). Puedes dejar esta ventana abierta."
  for i in $(seq 1 150); do
    READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
    printf "\r  Nodos Ready: %s/5 " "$READY"; [ "$READY" -ge 5 ] && break; sleep 10
  done; echo

  # Etiquetas role=… (Criterio 1). Idempotente.
  for n in $(kubectl get nodes --no-headers | awk '{print $1}'); do
    case "$n" in
      *worker-frontend*) kubectl label node "$n" role=frontend --overwrite ;;
      *worker-backend1*) kubectl label node "$n" role=backend1 --overwrite ;;
      *worker-backend2*) kubectl label node "$n" role=backend2 --overwrite ;;
      *worker-mongodb*)  kubectl label node "$n" role=mongodb  --overwrite ;;
    esac
  done
  if [ "${READY:-0}" -ge 5 ]; then
    pkill -f "http.server $JOIN_PORT" 2>/dev/null || true; rm -f "$PUBDIR/join.sh"   # ya no hace falta el token
    ok "Los 5 nodos están Ready y etiquetados."
  else
    info "Aún faltan nodos. Cuando se unan, re-ejecuta:  sudo bash node.sh master  (retoma y etiqueta)."
  fi
  kubectl get nodes --show-labels
  echo -e "\n${G}Siguiente paso (cuando la RDS esté 'Available'):${N}"
  echo "   cd ~/kubernetes/scripts/auto && cp -n config.env.example config.env && nano config.env   # solo RDS_PASSWORD"
  echo "   bash deploy.sh"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
step "3/4 WORKER ($ROLE) — preparar y esperar el join del master"
[ "$ROLE" = "mongodb" ] && { mkdir -p /data/mongodb; chmod 777 /data/mongodb; ok "carpeta /data/mongodb lista (hostPath de MongoDB)"; }

if [ -f /etc/kubernetes/kubelet.conf ]; then
  ok "Este nodo ya está unido al clúster. Nada que hacer."; exit 0
fi

# Etiqueta role=<rol> desde el propio kubelet: queda aplicada apenas se une el nodo.
echo "KUBELET_EXTRA_ARGS=--node-labels=role=$ROLE" > /etc/default/kubelet

# Diagnóstico claro si el Security Group bloquea al master (antes se veía como 'timeout' eterno)
if ! timeout 5 bash -c "</dev/tcp/$MASTER_IP/6443" 2>/dev/null; then
  info "No llego a $MASTER_IP:6443 todavía (¿master aún iniciando o SG sin 'All traffic' desde visons-workers-sg?). Reintento…"
fi

step "4/4 WORKER ($ROLE) — kubeadm join (token obtenido automáticamente)"
JOIN_FILE=$(mktemp)
for i in $(seq 1 180); do                      # hasta 30 min esperando al master
  curl -fsS -m 5 "http://$MASTER_IP:$JOIN_PORT/join.sh" -o "$JOIN_FILE" 2>/dev/null && break
  printf "\r  Esperando el join del master (%s/180)… " "$i"; sleep 10
done; echo
[ -s "$JOIN_FILE" ] || die "El master no publicó el join. Revisa que 'sudo bash node.sh master' esté corriendo y que el SG permita tráfico desde visons-workers-sg."
bash "$JOIN_FILE"
rm -f "$JOIN_FILE"
ok "Worker $HOSTNAME_NEW unido (rol=$ROLE). Verifica en el master:  kubectl get nodes --show-labels"

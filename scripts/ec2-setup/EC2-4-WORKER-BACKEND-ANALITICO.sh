#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║         EC2 #4 — WORKER NODE: BACKEND ANALÍTICO + BASES DE DATOS           ║
# ║         Stack: Flask Python 3.12 + MongoDB 7.0 + SQL Server 2022           ║
# ║         Plataforma: VISONS S.A.C.                                          ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  🏷️  ETIQUETAS AWS EC2 (Tags):                                              ║
# ║       Name        → visons-worker-backend2                                 ║
# ║       Role        → worker-backend-analitico                               ║
# ║       Environment → production                                              ║
# ║       Project     → visons-sac                                             ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  ☁️  CONFIGURACIÓN EC2 RECOMENDADA:                                         ║
# ║       Tipo:    t3.large (2 vCPU / 8 GB RAM) ← MongoDB + SQLServer + Flask  ║
# ║       OS:      Ubuntu 22.04 LTS                                            ║
# ║       Storage: 30 GB SSD (gp3)  ← para persistencia de BDs                ║
# ║       SG:      Puerto 30500 abierto al mundo                               ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  📋  QUÉ PONER EN LOS CAMPOS DE AWS:                                       ║
# ║                                                                             ║
# ║  → Key pair:   visons-key  (mismo que el master)                           ║
# ║  → VPC:        visons-vpc  (misma VPC que el master)                       ║
# ║  → Subnet:     Pública (misma AZ que el master)                            ║
# ║  → Security Group INBOUND:                                                 ║
# ║      22    TCP  0.0.0.0/0   (SSH)                                          ║
# ║      5000  TCP  <VPC CIDR>  (Flask API — interno)                          ║
# ║      27017 TCP  <VPC CIDR>  (MongoDB — solo acceso interno)                ║
# ║      1433  TCP  <VPC CIDR>  (SQL Server — solo acceso interno)             ║
# ║      30500 TCP  0.0.0.0/0   (NodePort API Analítica)                       ║
# ║      10250 TCP  <VPC CIDR>  (kubelet)                                      ║
# ║      8472  UDP  <VPC CIDR>  (Flannel VXLAN)                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# ▶ CÓMO USAR:
#   scp -i visons-key.pem EC2-4-WORKER-BACKEND-ANALITICO.sh ubuntu@<IP_WORKER4>:~/
#   ssh -i visons-key.pem ubuntu@<IP_WORKER4>
#   bash EC2-4-WORKER-BACKEND-ANALITICO.sh "<KUBEADM_JOIN_COMMAND>"

set -euo pipefail
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║          🏷️  ZONA DE VARIABLES — CAMBIA SOLO AQUÍ                      ║
# ╠══════════════════════════════════════════════════════════════════════════╣
MASTER_PRIVATE_IP="10.0.1.5"      # ← IP PRIVADA del EC2 Master (no la pública)
K8S_VERSION="1.30.0-1.1"          # ← Versión de Kubernetes (igual que el master)
# NOTA: El join command se pasa como argumento: bash bash "kubeadm join ..."
# ╚══════════════════════════════════════════════════════════════════════════╝
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_step() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}\n${CYAN}  🎯 $1${NC}\n${CYAN}══════════════════════════════════════════${NC}"; }
log_ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
log_info() { echo -e "${YELLOW}  ℹ  $1${NC}"; }

JOIN_CMD="${1:-}"
if [ -z "$JOIN_CMD" ]; then
    echo -e "${RED}❌ Debes pasar el kubeadm join command como argumento${NC}"
    echo    "   Ejemplo: bash $0 \"kubeadm join 10.0.1.5:6443 --token abc.xyz ...\""
    exit 1
fi

# ═══════════════════════════════════════════════════════
# PASO 1 — Actualizar sistema
# ═══════════════════════════════════════════════════════
log_step "1/5: Actualizando sistema"
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget apt-transport-https ca-certificates gnupg lsb-release
log_ok "Sistema actualizado"

# ═══════════════════════════════════════════════════════
# PASO 2 — Instalar Docker (con soporte extra de storage para BDs)
# ═══════════════════════════════════════════════════════
log_step "2/5: Instalando Docker (con soporte de volúmenes para BDs)"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable --now docker containerd
usermod -aG docker ubuntu

# Ajustar ulimits para SQL Server y MongoDB
cat > /etc/security/limits.d/99-sqlserver-mongo.conf << 'LIMITS'
* soft nofile 65536
* hard nofile 65536
* soft nproc  32768
* hard nproc  32768
LIMITS

# vm.max_map_count para que SQL Server / MongoDB no fallen
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
sysctl -p
log_ok "Docker instalado con ulimits para BDs"

# ═══════════════════════════════════════════════════════
# PASO 3 — Instalar kubelet + kubeadm
# ═══════════════════════════════════════════════════════
log_step "3/5: Instalando kubelet y kubeadm"
swapoff -a && sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
cat << 'EOF' > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf << 'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list
apt-get update -y
apt-get install -y kubelet=1.30.0-1.1 kubeadm=1.30.0-1.1
apt-mark hold kubelet kubeadm
log_ok "kubelet + kubeadm v1.30 instalados"

# ═══════════════════════════════════════════════════════
# PASO 4 — Unirse al clúster
# ═══════════════════════════════════════════════════════
log_step "4/5: Uniéndose al clúster como Worker (Backend Analítico)"
eval "$JOIN_CMD" --node-name="visons-worker-backend2" --ignore-preflight-errors=NumCPU,Mem
log_ok "Nodo unido al clúster"

# ═══════════════════════════════════════════════════════
# PASO 5 — Preparar carpetas de persistencia para las BDs
# ═══════════════════════════════════════════════════════
log_step "5/5: Preparando directorios de persistencia para MongoDB y SQL Server"

mkdir -p /data/mongodb
mkdir -p /data/sqlserver
chmod 777 /data/mongodb /data/sqlserver
chown -R 999:999 /data/sqlserver 2>/dev/null || true  # SQL Server corre como mssql (UID 999)

log_info "Directorios de BD creados en /data/mongodb y /data/sqlserver"
log_ok "Todo listo en este worker"

echo ""
echo -e "${BOLD}${GREEN}✅ WORKER BACKEND-ANALÍTICO + BDs UNIDO AL CLÚSTER${NC}"
echo ""
echo -e "${BOLD}📋 Desde el MASTER, aplica el label de rol:${NC}"
echo "  kubectl label node visons-worker-backend2 role=backend2 --overwrite"
echo "  kubectl taint node visons-worker-backend2 dedicated=backend2:NoSchedule --overwrite"
echo ""
echo -e "${BOLD}🔍 Verificar:${NC}"
echo "  kubectl get nodes -o wide"
echo ""
echo -e "${BOLD}🛢  Luego despliega las BDs desde el master:${NC}"
echo "  kubectl apply -f k8s/databases/mongodb.yaml"
echo "  kubectl apply -f k8s/databases/sqlserver.yaml"

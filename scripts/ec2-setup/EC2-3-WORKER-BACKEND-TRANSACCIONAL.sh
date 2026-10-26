#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║         EC2 #3 — WORKER NODE: BACKEND TRANSACCIONAL                        ║
# ║         Stack: Spring Boot WebFlux / Java 25                               ║
# ║         Plataforma: VISONS S.A.C.                                          ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  🏷️  ETIQUETAS AWS EC2 (Tags):                                              ║
# ║       Name        → visons-worker-backend1                                 ║
# ║       Role        → worker-backend-transaccional                           ║
# ║       Environment → production                                              ║
# ║       Project     → visons-sac                                             ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  ☁️  CONFIGURACIÓN EC2 RECOMENDADA:                                         ║
# ║       Tipo:    t3.medium (2 vCPU / 4 GB RAM)  ← Spring Boot necesita RAM   ║
# ║       OS:      Ubuntu 22.04 LTS                                            ║
# ║       Storage: 15 GB SSD (gp3)                                             ║
# ║       SG:      Puerto 30090 abierto al mundo                               ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  📋  QUÉ PONER EN LOS CAMPOS DE AWS:                                       ║
# ║                                                                             ║
# ║  → Key pair:   visons-key  (mismo que el master)                           ║
# ║  → VPC:        visons-vpc  (misma VPC que el master)                       ║
# ║  → Subnet:     Pública (misma AZ que el master)                            ║
# ║  → Security Group INBOUND:                                                 ║
# ║      22    TCP  0.0.0.0/0   (SSH)                                          ║
# ║      9090  TCP  <VPC CIDR>  (Spring Boot API — interno)                    ║
# ║      30090 TCP  0.0.0.0/0   (NodePort API Transaccional)                   ║
# ║      10250 TCP  <VPC CIDR>  (kubelet)                                      ║
# ║      8472  UDP  <VPC CIDR>  (Flannel VXLAN)                                ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# ▶ CÓMO USAR:
#   scp -i visons-key.pem EC2-3-WORKER-BACKEND-TRANSACCIONAL.sh ubuntu@<IP_WORKER3>:~/
#   ssh -i visons-key.pem ubuntu@<IP_WORKER3>
#   bash EC2-3-WORKER-BACKEND-TRANSACCIONAL.sh "<KUBEADM_JOIN_COMMAND>"

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

JOIN_CMD="${1:-}"
if [ -z "$JOIN_CMD" ]; then
    echo -e "${RED}❌ Debes pasar el kubeadm join command como argumento${NC}"
    echo    "   Ejemplo: bash $0 \"kubeadm join 10.0.1.5:6443 --token abc.xyz ...\""
    exit 1
fi

# ═══════════════════════════════════════════════════════
# PASO 1 — Actualizar sistema
# ═══════════════════════════════════════════════════════
log_step "1/4: Actualizando sistema"
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget apt-transport-https ca-certificates gnupg lsb-release
log_ok "Sistema actualizado"

# ═══════════════════════════════════════════════════════
# PASO 2 — Instalar Docker
# ═══════════════════════════════════════════════════════
log_step "2/4: Instalando Docker"
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
log_ok "Docker y containerd configurados con SystemdCgroup"

# ═══════════════════════════════════════════════════════
# PASO 3 — Instalar kubelet + kubeadm
# ═══════════════════════════════════════════════════════
log_step "3/4: Instalando kubelet y kubeadm"
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
log_step "4/4: Uniéndose al clúster como Worker (Backend Transaccional)"
eval "$JOIN_CMD" --node-name="visons-worker-backend1" --ignore-preflight-errors=NumCPU,Mem
log_ok "Nodo unido al clúster"

echo ""
echo -e "${BOLD}${GREEN}✅ WORKER BACKEND-TRANSACCIONAL UNIDO AL CLÚSTER${NC}"
echo ""
echo -e "${BOLD}📋 Desde el MASTER, aplica el label de rol:${NC}"
echo "  kubectl label node visons-worker-backend1 role=backend1 --overwrite"
echo "  kubectl taint node visons-worker-backend1 dedicated=backend1:NoSchedule --overwrite"
echo ""
echo -e "${BOLD}🔍 Verificar:${NC}"
echo "  kubectl get nodes -o wide"

#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║         EC2 #1 — NODO MASTER (Control Plane)                               ║
# ║         Plataforma: VISONS S.A.C.                                          ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  🏷️  ETIQUETAS AWS EC2 (Tags):                                              ║
# ║       Name        → visons-master                                          ║
# ║       Role        → control-plane                                           ║
# ║       Environment → production                                              ║
# ║       Project     → visons-sac                                             ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  ☁️  CONFIGURACIÓN EC2 RECOMENDADA:                                         ║
# ║       Tipo:    t3.medium (2 vCPU / 4 GB RAM)                               ║
# ║       OS:      Ubuntu 22.04 LTS                                            ║
# ║       Storage: 20 GB SSD (gp3)                                             ║
# ║       SG:      Puerto 6443 (API), 2379-2380 (etcd), 10250 (kubelet)        ║
# ║       EIP:     Sí (IP Elástica fija — esta es la MASTER_IP)                ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  📋  QUÉ PONER EN LOS CAMPOS DE AWS:                                       ║
# ║                                                                             ║
# ║  → Key pair:   visons-key  (o el nombre de tu .pem)                        ║
# ║  → VPC:        visons-vpc  (o la VPC por defecto)                          ║
# ║  → Subnet:     Pública (para que tenga IP pública)                         ║
# ║  → Security Group INBOUND:                                                 ║
# ║      22    TCP  0.0.0.0/0      (SSH)                                       ║
# ║      6443  TCP  0.0.0.0/0      (Kubernetes API)                            ║
# ║      2379  TCP  <VPC CIDR>     (etcd)                                      ║
# ║      2380  TCP  <VPC CIDR>     (etcd)                                      ║
# ║      10250 TCP  <VPC CIDR>     (kubelet)                                   ║
# ║      30080-30500 TCP 0.0.0.0/0 (NodePorts de los microservicios)           ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# ▶ CÓMO USAR:
#   scp -i visons-key.pem EC2-1-MASTER.sh ubuntu@<IP_MASTER>:~/
#   ssh -i visons-key.pem ubuntu@<IP_MASTER>
#   bash EC2-1-MASTER.sh

set -euo pipefail
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║          🏷️  ZONA DE VARIABLES — CAMBIA SOLO AQUÍ                      ║
# ╠══════════════════════════════════════════════════════════════════════════╣
MASTER_IP="54.0.0.0"               # ← IP Pública (EIP) de esta instancia EC2
MASTER_NODE_NAME="visons-master"   # ← Nombre del nodo en el clúster
POD_NETWORK_CIDR="10.244.0.0/16"  # ← CIDR de red de pods (Flannel)
K8S_VERSION="1.30.0-1.1"          # ← Versión de Kubernetes a instalar
# ╚══════════════════════════════════════════════════════════════════════════╝
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log_step() { echo -e "\n${CYAN}══════════════════════════════════════════${NC}\n${CYAN}  🎯 $1${NC}\n${CYAN}══════════════════════════════════════════${NC}"; }
log_ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
log_info() { echo -e "${YELLOW}  ℹ  $1${NC}"; }

# ═══════════════════════════════════════════════════════
# PASO 1 — Actualizar sistema
# ═══════════════════════════════════════════════════════
log_step "1/5: Actualizando sistema"
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget git net-tools apt-transport-https ca-certificates gnupg lsb-release
log_ok "Sistema actualizado"

# ═══════════════════════════════════════════════════════
# PASO 2 — Instalar Docker (container runtime)
# ═══════════════════════════════════════════════════════
log_step "2/5: Instalando Docker"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable --now docker containerd
usermod -aG docker ubuntu
log_ok "Docker y containerd configurados con SystemdCgroup"

# ═══════════════════════════════════════════════════════
# PASO 3 — Instalar kubeadm, kubelet, kubectl
# ═══════════════════════════════════════════════════════
log_step "3/5: Instalando Kubernetes (kubeadm + kubelet + kubectl)"

# Deshabilitar swap (requerido por Kubernetes)
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Cargar módulos de kernel necesarios
modprobe overlay && modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf << 'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

# Repositorio oficial de Kubernetes
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet=1.30.0-1.1 kubeadm=1.30.0-1.1 kubectl=1.30.0-1.1
apt-mark hold kubelet kubeadm kubectl
log_ok "kubeadm + kubelet + kubectl v1.30 instalados"

# ═══════════════════════════════════════════════════════
# PASO 4 — Inicializar el clúster (solo en el MASTER)
# ═══════════════════════════════════════════════════════
log_step "4/5: Inicializando clúster Kubernetes"

# ⚠️  Reemplaza <IP_PRIVADA_MASTER> con la IP privada de esta instancia EC2
# (La puedes ver en: curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

log_info "IP Privada: $PRIVATE_IP"
log_info "IP Pública: $PUBLIC_IP"

kubeadm init \
  --apiserver-advertise-address="$PRIVATE_IP" \
  --apiserver-cert-extra-sans="$PUBLIC_IP" \
  --pod-network-cidr=10.244.0.0/16 \
  --node-name="visons-master" \
  --ignore-preflight-errors=NumCPU,Mem | tee /tmp/kubeadm-init.log

# Configurar kubectl para el usuario ubuntu
mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown ubuntu:ubuntu /home/ubuntu/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

log_ok "Clúster inicializado"

# ═══════════════════════════════════════════════════════
# PASO 5 — Instalar CNI (Flannel)
# ═══════════════════════════════════════════════════════
log_step "5/5: Instalando CNI Flannel (red de pods)"
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
log_ok "Flannel aplicado"

# ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}✅ MASTER LISTO${NC}"
echo ""
echo -e "${BOLD}📋 GUARDA ESTE COMANDO para unir los Worker Nodes:${NC}"
echo ""
grep "kubeadm join" /tmp/kubeadm-init.log | tail -1
echo ""
echo -e "${BOLD}🔑 También puedes regenerar el join-command con:${NC}"
echo "  kubeadm token create --print-join-command"
echo ""
echo -e "${BOLD}🌐 Ahora ve al nodo Master desde tu máquina local:${NC}"
echo "  scp -i visons-key.pem ubuntu@$PUBLIC_IP:/home/ubuntu/.kube/config ~/.kube/config-visons"
echo "  export KUBECONFIG=~/.kube/config-visons"
echo "  kubectl get nodes"

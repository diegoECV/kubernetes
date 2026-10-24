#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║         EC2 #5 — WORKER NODE: MONGODB 7.0 (Base de Datos Documental)       ║
# ║         Plataforma: VISONS S.A.C.                                          ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  🏷️  ETIQUETAS AWS EC2 (Tags):                                              ║
# ║       Name        → visons-worker-mongodb                                  ║
# ║       Role        → worker-database-mongo                                  ║
# ║       Environment → production                                              ║
# ║       Project     → visons-sac                                             ║
# ║       DB          → mongodb                                                 ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  ☁️  CONFIGURACIÓN EC2 RECOMENDADA:                                         ║
# ║       Tipo:    t3.medium (2 vCPU / 4 GB RAM)                               ║
# ║       OS:      Ubuntu 22.04 LTS                                            ║
# ║       Storage: 20 GB SSD (gp3) — para datos de MongoDB                     ║
# ║       SG:      NO abrir 27017 al mundo (solo acceso interno VPC)           ║
# ╠══════════════════════════════════════════════════════════════════════════════╣
# ║  📋  QUÉ PONER EN LOS CAMPOS DE AWS:                                       ║
# ║                                                                             ║
# ║  → Key pair:    visons-key  (mismo que el master)                          ║
# ║  → VPC:         visons-vpc  (misma VPC que todos los demás)                ║
# ║  → Subnet:      Privada preferentemente (no necesita IP pública)           ║
# ║  → Security Group INBOUND:                                                 ║
# ║      22    TCP  <TU_IP>     (SSH — solo desde tu IP)                       ║
# ║      27017 TCP  <VPC CIDR>  (MongoDB — SOLO acceso interno del clúster)    ║
# ║      10250 TCP  <VPC CIDR>  (kubelet)                                      ║
# ║      8472  UDP  <VPC CIDR>  (Flannel VXLAN)                                ║
# ║                                                                             ║
# ║  → Security Group OUTBOUND:                                                ║
# ║      Todo el tráfico (para pull de imágenes Docker Hub)                    ║
# ║                                                                             ║
# ║  ⚠️  IMPORTANTE:                                                            ║
# ║      NO abrir el puerto 27017 a 0.0.0.0/0 — es una base de datos          ║
# ║      Solo debe ser accesible desde dentro de la VPC (backend pods)         ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
#
# ▶ CÓMO USAR (después de correr EC2-1-MASTER.sh):
#   scp -i visons-key.pem EC2-5-WORKER-MONGODB.sh ubuntu@<IP_WORKER_MONGO>:~/
#   ssh -i visons-key.pem ubuntu@<IP_WORKER_MONGO>
#   sudo bash EC2-5-WORKER-MONGODB.sh "<KUBEADM_JOIN_COMMAND>"
#
# Ejemplo:
#   sudo bash EC2-5-WORKER-MONGODB.sh "kubeadm join 10.0.1.5:6443 --token abc.xyz --discovery-token-ca-cert-hash sha256:1234..."

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
    echo    "   Ejemplo: sudo bash $0 \"kubeadm join 10.0.1.5:6443 --token abc.xyz ...\""
    exit 1
fi

# ═══════════════════════════════════════════════════════
# PASO 1 — Actualizar sistema
# ═══════════════════════════════════════════════════════
log_step "1/6: Actualizando sistema"
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget apt-transport-https ca-certificates gnupg lsb-release net-tools
log_ok "Sistema actualizado"

# ═══════════════════════════════════════════════════════
# PASO 2 — Optimizar kernel para MongoDB
# ═══════════════════════════════════════════════════════
log_step "2/6: Optimizando kernel para MongoDB"

# MongoDB requiere vm.max_map_count alto
echo "vm.max_map_count=262144"        >> /etc/sysctl.conf
echo "vm.swappiness=1"                >> /etc/sysctl.conf   # MongoDB prefiere RAM
echo "net.core.somaxconn=65535"       >> /etc/sysctl.conf
echo "net.ipv4.tcp_max_syn_backlog=65535" >> /etc/sysctl.conf
sysctl -p

# Límites de archivos abiertos para MongoDB
cat > /etc/security/limits.d/99-mongodb.conf << 'LIMITS'
mongodb soft nofile 64000
mongodb hard nofile 64000
mongodb soft nproc  64000
mongodb hard nproc  64000
*       soft nofile 65536
*       hard nofile 65536
LIMITS

# Deshabilitar Transparent Huge Pages (recomendado por MongoDB)
echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled
echo 'never' > /sys/kernel/mm/transparent_hugepage/defrag

# Persistir en reboot
cat > /etc/rc.local << 'RCLOCAL'
#!/bin/bash
echo 'never' > /sys/kernel/mm/transparent_hugepage/enabled
echo 'never' > /sys/kernel/mm/transparent_hugepage/defrag
exit 0
RCLOCAL
chmod +x /etc/rc.local

log_ok "Kernel optimizado para MongoDB"

# ═══════════════════════════════════════════════════════
# PASO 3 — Instalar Docker
# ═══════════════════════════════════════════════════════
log_step "3/6: Instalando Docker"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y && apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable --now docker
usermod -aG docker ubuntu
log_ok "Docker instalado"

# ═══════════════════════════════════════════════════════
# PASO 4 — Instalar kubelet + kubeadm
# ═══════════════════════════════════════════════════════
log_step "4/6: Instalando kubelet y kubeadm"

# Deshabilitar swap (obligatorio para Kubernetes)
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Módulos de kernel
modprobe overlay && modprobe br_netfilter
cat > /etc/sysctl.d/k8s.conf << 'SYSCTL'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

# Repositorio Kubernetes v1.30
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
# PASO 5 — Preparar volumen de datos para MongoDB
# ═══════════════════════════════════════════════════════
log_step "5/6: Preparando directorio de persistencia de MongoDB"

mkdir -p /data/mongodb
chmod 777 /data/mongodb

# Si hay un disco adicional montado (ej: /dev/xvdb), úsalo para mejor performance
if lsblk | grep -q "xvdb"; then
    log_info "Disco adicional /dev/xvdb detectado — montando en /data/mongodb"
    mkfs.ext4 /dev/xvdb -F
    echo "/dev/xvdb  /data/mongodb  ext4  defaults,noatime  0  2" >> /etc/fstab
    mount -a
    chmod 777 /data/mongodb
    log_ok "Disco adicional montado en /data/mongodb"
else
    log_info "Sin disco adicional — usando disco principal para /data/mongodb"
fi

log_ok "Directorio /data/mongodb preparado"

# ═══════════════════════════════════════════════════════
# PASO 6 — Unirse al clúster Kubernetes
# ═══════════════════════════════════════════════════════
log_step "6/6: Uniéndose al clúster como Worker (MongoDB)"
eval "$JOIN_CMD" --node-name="visons-worker-mongodb"
log_ok "Nodo unido al clúster"

# ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}✅ WORKER MONGODB LISTO Y UNIDO AL CLÚSTER${NC}"
echo ""
echo -e "${BOLD}📋 Desde el MASTER, aplica el label de rol:${NC}"
echo ""
echo "  # Label y taint para que solo MongoDB se ejecute aquí"
echo "  kubectl label node visons-worker-mongodb role=database-mongo --overwrite"
echo "  kubectl taint node visons-worker-mongodb dedicated=database:NoSchedule --overwrite"
echo ""
echo -e "${BOLD}🛢  Desplegar MongoDB en este nodo:${NC}"
echo "  kubectl apply -f k8s/databases/mongodb.yaml"
echo ""
echo -e "${BOLD}🔍 Verificar que el pod corre en este nodo:${NC}"
echo "  kubectl get pods -n visons-prod -l app=mongodb -o wide"
echo ""
echo -e "${BOLD}📡 Conectividad interna (desde otro pod del clúster):${NC}"
echo "  mongodb://admin:admin123@mongodb-service:27017/Visons?authSource=admin"
echo ""
echo -e "${BOLD}⚠️  Recuerda:${NC}"
echo "  El puerto 27017 solo debe estar abierto dentro de la VPC."
echo "  NO expongas MongoDB directamente a Internet."

# 📘 GUÍA MAESTRA DE EXAMEN: PLATAFORMA VISONS S.A.C.
> **Manual Práctico Paso a Paso Organizado por Instancia y por Grupo de Seguridad**  
> *Despliegue Multi-Nodo Kubernetes (Kubeadm) en AWS EC2 + Persistencia Políglota (RDS SQL Server + MongoDB)*  
> **Autor:** Diego Centeno | **Proyecto:** Visons S.A.C.

---

# 🛡️ PARTE 1: TABLAS DE GRUPOS DE SEGURIDAD (SECURITY GROUPS)

Si en el examen te piden crear un Security Group específico para cada máquina, configura las siguientes reglas de **Entrada (Inbound Rules)**:

---

### 1. Security Group: `sg-visons-master`
> **Asignar a:** Instancia `visons-master`

| Tipo de Tráfico | Protocolo | Puerto / Rango | Origen (Source) | Justificación para el Evaluador |
| :--- | :--- | :--- | :--- | :--- |
| **SSH** | TCP | `22` | `0.0.0.0/0` | Conexión administrativa y EC2 Instance Connect |
| **K8s API Server** | TCP | `6443` | `172.31.0.0/16` (VPC) | Endpoint al que se conectan los 4 Worker Nodes |
| **etcd database** | TCP | `2379 - 2380` | `172.31.0.0/16` (VPC) | Base de datos de estado del clúster |
| **Kubelet API** | TCP | `10250` | `172.31.0.0/16` (VPC) | Control de pods en el Master |
| **Kube-Scheduler** | TCP | `10259` | `172.31.0.0/16` (VPC) | Planificador de pods |
| **Kube-Controller** | TCP | `10257` | `172.31.0.0/16` (VPC) | Controlador del clúster |
| **Flannel CNI** | **UDP** | **`8472`** | `172.31.0.0/16` (VPC) | **Red overlay VXLAN de pods (Obligatorio UDP)** |
| **NodePort Frontend** | TCP | `30080` | `0.0.0.0/0` | Acceso público web a la aplicación React |
| **NodePort Swagger** | TCP | `30090` | `0.0.0.0/0` | Documentación interactiva y APIs Spring Boot |
| **NodePort Analítica**| TCP | `30500` | `0.0.0.0/0` | Acceso a KPIs del Backend Flask |

---

### 2. Security Group: `sg-visons-worker-frontend`
> **Asignar a:** Instancia `visons-worker-frontend`

| Tipo de Tráfico | Protocolo | Puerto / Rango | Origen (Source) | Justificación para el Evaluador |
| :--- | :--- | :--- | :--- | :--- |
| **SSH** | TCP | `22` | `0.0.0.0/0` | Administración remota |
| **Kubelet API** | TCP | `10250` | `172.31.0.0/16` (VPC) | Comunicación con el API Server del Master |
| **Flannel CNI** | **UDP** | **`8472`** | `172.31.0.0/16` (VPC) | Comunicación de red con los otros pods |
| **NodePort Web** | TCP | `30080` | `0.0.0.0/0` | Tráfico directo al contenedor Nginx |
| **Kube-Proxy Mesh** | TCP | `30000 - 32767`| `172.31.0.0/16` (VPC) | Enrutamiento interno NodePort entre nodos |

---

### 3. Security Group: `sg-visons-worker-backend1` (Transaccional)
> **Asignar a:** Instancia `visons-worker-backend1`

| Tipo de Tráfico | Protocolo | Puerto / Rango | Origen (Source) | Justificación para el Evaluador |
| :--- | :--- | :--- | :--- | :--- |
| **SSH** | TCP | `22` | `0.0.0.0/0` | Administración remota |
| **Kubelet API** | TCP | `10250` | `172.31.0.0/16` (VPC) | Comunicación con el API Server del Master |
| **Flannel CNI** | **UDP** | **`8472`** | `172.31.0.0/16` (VPC) | Comunicación de red con los otros pods |
| **NodePort API** | TCP | `30090` | `0.0.0.0/0` | Acceso a endpoints de Spring Boot WebFlux |
| **Kube-Proxy Mesh** | TCP | `30000 - 32767`| `172.31.0.0/16` (VPC) | Enrutamiento interno NodePort entre nodos |

---

### 4. Security Group: `sg-visons-worker-backend2` (Analítico)
> **Asignar a:** Instancia `visons-worker-backend2`

| Tipo de Tráfico | Protocolo | Puerto / Rango | Origen (Source) | Justificación para el Evaluador |
| :--- | :--- | :--- | :--- | :--- |
| **SSH** | TCP | `22` | `0.0.0.0/0` | Administración remota |
| **Kubelet API** | TCP | `10250` | `172.31.0.0/16` (VPC) | Comunicación con el API Server del Master |
| **Flannel CNI** | **UDP** | **`8472`** | `172.31.0.0/16` (VPC) | Comunicación de red con los otros pods |
| **NodePort KPIs** | TCP | `30500` | `0.0.0.0/0` | Acceso al servicio analítico en Python |
| **Kube-Proxy Mesh** | TCP | `30000 - 32767`| `172.31.0.0/16` (VPC) | Enrutamiento interno NodePort entre nodos |

---

### 5. Security Group: `sg-visons-worker-mongodb` (Base de Datos NoSQL)
> **Asignar a:** Instancia `visons-worker-mongodb`

| Tipo de Tráfico | Protocolo | Puerto / Rango | Origen (Source) | Justificación para el Evaluador |
| :--- | :--- | :--- | :--- | :--- |
| **SSH** | TCP | `22` | `0.0.0.0/0` | Administración remota |
| **Kubelet API** | TCP | `10250` | `172.31.0.0/16` (VPC) | Comunicación con el API Server del Master |
| **Flannel CNI** | **UDP** | **`8472`** | `172.31.0.0/16` (VPC) | Comunicación de red con los otros pods |
| **MongoDB Service** | TCP | `27017` | `172.31.0.0/16` (VPC) | Conexión interna del Backend Analítico a MongoDB |
| **Kube-Proxy Mesh** | TCP | `30000 - 32767`| `172.31.0.0/16` (VPC) | Enrutamiento interno NodePort entre nodos |

---

### 6. Security Group: `sg-visons-rds-sqlserver` (Amazon RDS)
> **Asignar a:** Instancia de Base de Datos Amazon RDS

| Tipo de Tráfico | Protocolo | Puerto / Rango | Origen (Source) | Justificación para el Evaluador |
| :--- | :--- | :--- | :--- | :--- |
| **MS SQL Server** | TCP | `1433` | `172.31.0.0/16` (VPC) | Permite peticiones R2DBC y PyODBC desde los workers |

> 💡 **Opción Rápida para el Examen:** Si el evaluador no exige 6 grupos distintos, puedes crear un único grupo llamado **`sg-visons-cluster`** que contenga todos estos puertos y asociarlo a las 5 máquinas EC2 y a la RDS.

---

# 💻 PARTE 2: COMANDOS EXACTOS POR CADA INSTANCIA (1 A 1)

Sigue el orden de las letras: abre la terminal de cada máquina y pega su bloque completo.

---

## 🟢 INSTANCIA 1: `visons-master` (Paso 1 de 2)
> Conéctate por EC2 Instance Connect a **`visons-master`** y pega este bloque:

```bash
# 1. Configurar Hostname
sudo hostnamectl set-hostname visons-master

# 2. Deshabilitar Swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 3. Cargar módulos del kernel de forma permanente (overlay y br_netfilter)
sudo tee /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter

# 4. Configurar parámetros sysctl
sudo tee /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 5. Instalar containerd con SystemdCgroup
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd && sudo systemctl enable containerd

# 6. Instalar kubeadm, kubelet y kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 7. Inicializar Kubernetes en el Master
PRIVATE_IP=$(hostname -I | awk '{print $1}')
sudo kubeadm init \
  --apiserver-advertise-address="$PRIVATE_IP" \
  --pod-network-cidr=10.244.0.0/16 \
  --node-name=visons-master \
  --ignore-preflight-errors=NumCPU,Mem | tee /tmp/kubeadm-init.log

# 8. Configurar credenciales para kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 9. Instalar CNI Flannel
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

# 10. Copiar el comando JOIN para los workers:
echo "=== COPIA ESTE COMANDO JOIN PARA LOS WORKERS ==="
grep -A 2 "kubeadm join" /tmp/kubeadm-init.log | tail -2
```

---

## 🟢 INSTANCIA 2: `visons-worker-frontend`
> Conéctate por EC2 Instance Connect a **`visons-worker-frontend`** y pega este bloque:

```bash
# 1. Configurar Hostname
sudo hostnamectl set-hostname visons-worker-frontend

# 2. Deshabilitar Swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 3. Módulos de red persistentes
sudo tee /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter

# 4. Sysctl
sudo tee /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 5. Instalar containerd con SystemdCgroup
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd && sudo systemctl enable containerd

# 6. Instalar kubelet y kubeadm
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm

echo "✅ Nodo listo. Ahora pega aquí el comando 'sudo kubeadm join ...' obtenido del Master."
```
*(Luego de ejecutar este bloque, pega el comando `sudo kubeadm join ...` que te dio el Master).*

---

## 🟢 INSTANCIA 3: `visons-worker-backend1`
> Conéctate por EC2 Instance Connect a **`visons-worker-backend1`** y pega este bloque:

```bash
# 1. Configurar Hostname
sudo hostnamectl set-hostname visons-worker-backend1

# 2. Deshabilitar Swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 3. Módulos de red persistentes
sudo tee /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter

# 4. Sysctl
sudo tee /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 5. Instalar containerd con SystemdCgroup
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd && sudo systemctl enable containerd

# 6. Instalar kubelet y kubeadm
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm

echo "✅ Nodo listo. Ahora pega aquí el comando 'sudo kubeadm join ...' obtenido del Master."
```
*(Pega el comando `sudo kubeadm join ...`).*

---

## 🟢 INSTANCIA 4: `visons-worker-backend2`
> Conéctate por EC2 Instance Connect a **`visons-worker-backend2`** y pega este bloque:

```bash
# 1. Configurar Hostname
sudo hostnamectl set-hostname visons-worker-backend2

# 2. Deshabilitar Swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 3. Módulos de red persistentes
sudo tee /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter

# 4. Sysctl
sudo tee /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 5. Instalar containerd con SystemdCgroup
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd && sudo systemctl enable containerd

# 6. Instalar kubelet y kubeadm
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm

echo "✅ Nodo listo. Ahora pega aquí el comando 'sudo kubeadm join ...' obtenido del Master."
```
*(Pega el comando `sudo kubeadm join ...`).*

---

## 🟢 INSTANCIA 5: `visons-worker-mongodb`
> Conéctate por EC2 Instance Connect a **`visons-worker-mongodb`** y pega este bloque:

```bash
# 1. Configurar Hostname
sudo hostnamectl set-hostname visons-worker-mongodb

# 2. Deshabilitar Swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 3. Módulos de red persistentes
sudo tee /etc/modules-load.d/k8s.conf << 'EOF'
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter

# 4. Sysctl
sudo tee /etc/sysctl.d/k8s.conf << 'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 5. Instalar containerd con SystemdCgroup
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd && sudo systemctl enable containerd

# 6. Instalar kubelet y kubeadm
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update && sudo apt-get install -y kubelet kubeadm
sudo apt-mark hold kubelet kubeadm

# 7. Crear el directorio de datos persistente para MongoDB
sudo mkdir -p /data/mongodb
sudo chmod 777 /data/mongodb

echo "✅ Nodo listo. Ahora pega aquí el comando 'sudo kubeadm join ...' obtenido del Master."
```
*(Pega el comando `sudo kubeadm join ...`).*

---

## 🟢 DE VUELTA A LA INSTANCIA 1: `visons-master` (Paso 2 de 2 - Despliegue)
> Regresa a la terminal de **`visons-master`** para completar el despliegue de las aplicaciones:

```bash
# 1. Asignar las etiquetas de aislamiento dedicado a los Workers:
kubectl label node visons-worker-frontend role=frontend --overwrite
kubectl label node visons-worker-backend1 role=backend-transaccional --overwrite
kubectl label node visons-worker-backend2 role=backend-analitico --overwrite
kubectl label node visons-worker-mongodb role=mongodb --overwrite

# 2. Confirmar que los 5 nodos estén en Ready con sus etiquetas:
kubectl get nodes -o wide --show-labels

# 3. Clonar el repositorio de Kubernetes:
cd ~
git clone https://github.com/diegoECV/kubernetes.git
cd kubernetes

# 4. CONFIGURAR TUS DATOS DE RDS Y ELASTIC IP:
RDS_ENDPOINT="visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com"  # ← Pega aquí tu Endpoint de RDS
RDS_PASSWORD="diego1416"                                          # ← Pega aquí la contraseña de tu RDS
RDS_USER="admin"                                                  # ← Usuario de tu RDS
ELASTIC_IP="52.20.37.223"                                         # ← Tu IP pública del Master

# Inyectar la conexión de la RDS y la IP en el ConfigMap y Secrets:
sed -i "s|SPRING_R2DBC_URL:.*|SPRING_R2DBC_URL: \"r2dbc:mssql://$RDS_ENDPOINT:1433/Visons\"|g" k8s/02-configmaps.yaml
sed -i "s|SPRING_R2DBC_USERNAME:.*|SPRING_R2DBC_USERNAME: \"$RDS_USER\"|g" k8s/02-configmaps.yaml
sed -i "s|SQL_SERVER:.*|SQL_SERVER: \"$RDS_ENDPOINT\"|g" k8s/02-configmaps.yaml
sed -i "s|SQL_USER:.*|SQL_USER: \"$RDS_USER\"|g" k8s/02-configmaps.yaml
sed -i "s|FRONTEND_URL:.*|FRONTEND_URL: \"http://$ELASTIC_IP:30080\"|g" k8s/02-configmaps.yaml

sed -i "s|SPRING_R2DBC_PASSWORD:.*|SPRING_R2DBC_PASSWORD: \"$RDS_PASSWORD\"|g" k8s/01-secrets.yaml
sed -i "s|SQL_PASSWORD:.*|SQL_PASSWORD: \"$RDS_PASSWORD\"|g" k8s/01-secrets.yaml

# 5. Desplegar los manifiestos de Kubernetes en orden:
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-secrets.yaml
kubectl apply -f k8s/02-configmaps.yaml
kubectl apply -f k8s/databases/mongodb.yaml
kubectl apply -f k8s/backend-transaccional/
kubectl apply -f k8s/backend-analitico/
kubectl apply -f k8s/frontend-web/

# 5. Esperar a que los pods alcancen 1/1 Running:
echo "Esperando a que los pods levanten..."
sleep 25
kubectl get pods -n visons-prod -o wide
```

---

## 🟢 INYECCIÓN FINAL DE LA IP ELÁSTICA EN EL FRONTEND
> Ejecuta esto en el Master reemplazando `52.73.219.160` por la IP Elástica asignada a tu Master:

```bash
ELASTIC_IP="52.73.219.160"  # ← Pon tu IP Elástica de AWS aquí

# Inyectar la IP en los archivos estáticos en ejecución:
kubectl exec -n visons-prod deployment/frontend-web -- sh -c "sed -i 's|http://localhost:9090|http://'$ELASTIC_IP':30090|g; s|http://localhost:5000|http://'$ELASTIC_IP':30500|g; s|34.228.12.107|'$ELASTIC_IP'|g; s|54.234.91.155|'$ELASTIC_IP'|g' /usr/share/nginx/html/assets/*.js"

# Verificar que la IP quedó grabada:
kubectl exec -n visons-prod deployment/frontend-web -- sh -c "grep -o '$ELASTIC_IP:30090' /usr/share/nginx/html/assets/*.js" | head -1
```

---

## 🎯 PRUEBA MAESTRA PARA OBTENER 20/20 EN EL EXAMEN
Copia y pega este bloque en **`visons-master`** frente a tu profesor o evaluador:

```bash
echo "=== 1. CLÚSTER MULTI-NODO (5 NODOS READY) ==="
kubectl get nodes -o wide

echo -e "\n=== 2. AISLAMIENTO DE PODS DEDICADOS ==="
kubectl get pods -n visons-prod -o wide

echo -e "\n=== 3. PRUEBA FRONTEND WEB (HTTP 200) ==="
curl -s -o /dev/null -w "Frontend HTTP: %{http_code}\n" http://localhost:30080

echo -e "\n=== 4. PRUEBA SWAGGER UI (HTTP 200) ==="
curl -s -o /dev/null -w "Swagger API HTTP: %{http_code}\n" http://localhost:30090/v3/api-docs

echo -e "\n=== 5. PRUEBA LOGIN REAL CONTRA RDS SQL SERVER (TOKEN JWT) ==="
curl -s -X POST http://localhost:30090/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin@visons.com","password":"password123"}'
echo ""

echo -e "\n=== 6. PRUEBA BACKEND ANALÍTICO (CONSULTA A MONGODB) ==="
curl -s http://localhost:30500/api/v1/analytics/dashboard/kpis | cut -c 1-130
echo ""
```

### URLs en el Navegador Web:
- 🌐 **Frontend Visons:** `http://<ELASTIC_IP>:30080` (Login: `admin@visons.com` / `password123`)
- 📚 **Swagger UI:** `http://<ELASTIC_IP>:30090/swagger-ui.html`
- 📊 **KPIs Analítica:** `http://<ELASTIC_IP>:30500/api/v1/analytics/dashboard/kpis`

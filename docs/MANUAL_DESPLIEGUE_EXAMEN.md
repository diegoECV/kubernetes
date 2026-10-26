# 📘 MANUAL MAESTRO DEFINITIVO DE DESPLIEGUE: PLATAFORMA VISONS S.A.C.
> **Guía Ejecutable Paso a Paso de Principio a Fin — Arquitectura 100% Real**  
> **Clúster Kubernetes Multi-Nodo (5 EC2) + Persistencia Políglota (Amazon RDS SQL Server + MongoDB)**  
> **Repositorio Oficial:** `https://github.com/diegoECV/kubernetes.git`  
> **Autor:** Diego Centeno | **Proyecto:** Visons S.A.C.

---

## 📌 0. VARIABLES DE CONFIGURACIÓN GLOBAL
> Antes de ejecutar cualquier comando, define tus variables en una hoja de notas o cárgalas en la terminal. **IMPORTANTE:** Todas las contraseñas se definen entre comillas simples `'...'` para evitar que Bash las interprete como eventos de historial si contienen signos como `!`.

```bash
# =============================================================================
# VARIABLES GLOBALES DEL ENTORNO DE EVALUACIÓN
# =============================================================================
export AWS_REGION="us-east-1"
export VPC_CIDR="172.31.0.0/16"
export PREFIX_LIST_EIC="com.amazonaws.us-east-1.ec2-instance-connect"

# Obtén tu IP pública actual para permitir tu acceso administrativo:
export MY_IP="$(curl -s https://checkip.amazonaws.com)/32"

# Parámetros de Amazon RDS SQL Server:
export RDS_ENDPOINT="visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com"
export RDS_PORT="1433"
export RDS_USER="admin"
export RDS_PASSWORD='tu_password_rds'  # ← Pon tu contraseña real aquí entre comillas simples

# Parámetros del Master de Kubernetes (asignar tras lanzar EC2):
export MASTER_PUBLIC_IP="52.20.37.223"   # ← IP pública de visons-master
export MASTER_PRIVATE_IP="172.31.20.216" # ← IP privada de visons-master
```

---

## 🛡️ SECCIÓN 1: CREACIÓN DE SECURITY GROUPS (3 EN TOTAL)
> **Principio de Diseño:** Los Security Groups se crean primero **completamente vacíos** y luego se les inyectan las reglas. Esto es obligatorio porque se referencian entre sí como origen (Source SG), evitando errores de dependencia circular en AWS.

### Paso 1.1: Crear los 3 Security Groups vacíos en AWS

* **Máquina donde se ejecuta:** Consola AWS (CloudShell) o tu máquina local con AWS CLI:

```bash
# 1. Security Group para el Master
SG_MASTER_ID=$(aws ec2 create-security-group \
  --group-name "sg-visons-master" \
  --description "Security Group para visons-master control-plane" \
  --vpc-id $(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text) \
  --output text --query "GroupId")

# 2. Security Group para los 4 Workers
SG_WORKERS_ID=$(aws ec2 create-security-group \
  --group-name "sg-visons-workers" \
  --description "Security Group unificado para los 4 worker nodes de visons" \
  --vpc-id $(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text) \
  --output text --query "GroupId")

# 3. Security Group para Amazon RDS SQL Server
SG_RDS_ID=$(aws ec2 create-security-group \
  --group-name "sg-visons-rds" \
  --description "Security Group exclusivo para Amazon RDS SQL Server" \
  --vpc-id $(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text) \
  --output text --query "GroupId")

echo "SG Master : $SG_MASTER_ID"
echo "SG Workers: $SG_WORKERS_ID"
echo "SG RDS    : $SG_RDS_ID"
```

---

### Paso 1.2: Configurar las Reglas de Entrada (Inbound Rules)

#### A. Reglas para `sg-visons-master`:
* **Máquina donde se ejecuta:** AWS CloudShell o AWS CLI:

```bash
# 1. SSH (22) desde tu IP y desde EC2 Instance Connect
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 22 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 22 --prefix-list-id $(aws ec2 describe-managed-prefix-lists --filters "Name=prefix-list-name,Values=*ec2-instance-connect" --query "PrefixLists[0].PrefixListId" --output text)

# 2. K8s API Server (6443) desde tu IP y desde los Workers
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 6443 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 6443 --source-group $SG_WORKERS_ID

# 3. NodePorts públicos (30080 Frontend, 30090 Backend1, 30500 Backend2)
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30080 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30090 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30500 --cidr 0.0.0.0/0

# 4. Monitoreo (30300 Grafana y 30091 Prometheus) solo desde tu IP
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30300 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30091 --cidr $MY_IP

# 5. Todo el tráfico interno desde los Workers (CNI Flannel VXLAN, Kubelet 10250, etcd)
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol all --source-group $SG_WORKERS_ID
```

#### B. Reglas para `sg-visons-workers`:
* **Máquina donde se ejecuta:** AWS CloudShell o AWS CLI:

```bash
# 1. SSH (22) desde tu IP y desde EC2 Instance Connect
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 22 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 22 --prefix-list-id $(aws ec2 describe-managed-prefix-lists --filters "Name=prefix-list-name,Values=*ec2-instance-connect" --query "PrefixLists[0].PrefixListId" --output text)

# 2. Kubelet API (10250) desde el Master (elimina timeouts de kubectl exec/logs)
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 10250 --source-group $SG_MASTER_ID

# 3. Todo el tráfico desde el Master y entre Workers (comunicación pod-a-pod y Flannel)
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol all --source-group $SG_MASTER_ID
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol all --source-group $SG_WORKERS_ID

# 4. Rango NodePort (30000-32767) dentro de la VPC para balanceo kube-proxy
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 30000-32767 --cidr $VPC_CIDR

# 5. NodePort 30080 público directo para acceso Web
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 30080 --cidr 0.0.0.0/0

# 6. MongoDB (27017) estricto: SOLO accesible dentro del Security Group de Workers
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 27017 --source-group $SG_WORKERS_ID
```

#### C. Reglas para `sg-visons-rds`:
* **Máquina donde se ejecuta:** AWS CloudShell o AWS CLI:

```bash
# SQL Server (1433) accesible ÚNICAMENTE desde el Master y desde los Workers
aws ec2 authorize-security-group-ingress --group-id $SG_RDS_ID --protocol tcp --port 1433 --source-group $SG_MASTER_ID
aws ec2 authorize-security-group-ingress --group-id $SG_RDS_ID --protocol tcp --port 1433 --source-group $SG_WORKERS_ID
```

> **Egress:** Los tres Security Groups mantienen la regla de salida por defecto permitiendo todo (`0.0.0.0/0`), necesaria para descargar paquetes de Ubuntu, imágenes de Docker Hub y actualizaciones.

✅ **Verificación de Security Groups:**
```bash
# Ejecutar en AWS CloudShell o CLI:
aws ec2 describe-security-groups --group-ids $SG_MASTER_ID $SG_WORKERS_ID $SG_RDS_ID --query "SecurityGroups[*].[GroupName,GroupId]" --output table
```
*Salida esperada:* Lista con los 3 grupos creados y asociados a la VPC.

---

## 💻 SECCIÓN 2: APROVISIONAMIENTO DE LAS 5 INSTANCIAS EC2
> Se lanzan exactamente **5 instancias EC2** bajo Ubuntu 22.04 / 24.04 LTS:

| # | Nombre de la Instancia | Rol en Kubernetes | Tipo de Instancia | Disco | Security Group Asignado |
|---|---|---|---|---|---|
| **1** | `visons-master` | Control-Plane | **t3.medium** (2 vCPU, 4GB) | 20 GB gp3 | `sg-visons-master` |
| **2** | `visons-worker-frontend` | Worker Frontend | **t3.small** / **t3.medium** | 15 GB gp3 | `sg-visons-workers` |
| **3** | `visons-worker-backend1` | Worker Backend 1 | **t3.medium** (2 vCPU, 4GB) | 20 GB gp3 | `sg-visons-workers` |
| **4** | `visons-worker-backend2` | Worker Backend 2 | **t3.medium** (2 vCPU, 4GB) | 20 GB gp3 | `sg-visons-workers` |
| **5** | `visons-worker-mongodb` | Worker MongoDB | **t3.medium** (2 vCPU, 4GB) | 20 GB gp3 | `sg-visons-workers` |

---

### Paso 2.1: Pre-requisitos comunes en las 5 Instancias
* **Máquina donde se ejecuta:** En **CADA UNA** de las 5 instancias (Master y 4 Workers):

```bash
# 1. Desactivar Swap (Obligatorio para Kubernetes)
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# 2. Configurar módulos de kernel para red de contenedores
cat << 'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# 3. Parámetros sysctl para puenteo de paquetes de red
cat << 'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# 4. Instalar containerd como runtime de contenedores
sudo apt-get update -qq
sudo apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -qq
sudo apt-get install -y -qq containerd.io

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# 5. Instalar kubelet, kubeadm y kubectl (v1.28 - v1.31)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

✅ **Verificación en cada máquina:**
```bash
swapon --show
sudo systemctl is-active containerd kubelet
```
*Salida esperada:* `swapon --show` devuelve vacío y ambos servicios responden `active`.

---

## 🔗 SECCIÓN 3: UNIÓN DE LOS 4 WORKERS AL CLÚSTER (KUBEADM)

### Paso 3.1: Inicializar el Master
* **Máquina donde se ejecuta:** `visons-master`

```bash
# 1. Fijar hostname persistente
sudo hostnamectl set-hostname visons-master
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# 2. Inicializar Kubeadm con red pod CIDR de Flannel (10.244.0.0/16)
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# 3. Configurar kubeconfig para el usuario ubuntu
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 4. Desplegar el CNI Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 5. Generar y mostrar el comando de unión (Token join):
sudo kubeadm token create --print-join-command
```

---

### Paso 3.2: Ejecutar el Join en cada Worker Node
> Conéctate por **EC2 Instance Connect** a cada worker y ejecuta su bloque correspondiente.

#### A. En la máquina: `visons-worker-frontend`
```bash
sudo hostnamectl set-hostname visons-worker-frontend
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Pegar el comando generado por kubeadm token create:
sudo kubeadm join 172.31.20.216:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

#### B. En la máquina: `visons-worker-backend1`
```bash
sudo hostnamectl set-hostname visons-worker-backend1
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Pegar el comando generado por kubeadm token create:
sudo kubeadm join 172.31.20.216:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

#### C. En la máquina: `visons-worker-backend2`
```bash
sudo hostnamectl set-hostname visons-worker-backend2
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Pegar el comando generado por kubeadm token create:
sudo kubeadm join 172.31.20.216:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

#### D. En la máquina: `visons-worker-mongodb`
```bash
sudo hostnamectl set-hostname visons-worker-mongodb
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Crear directorio local para persistencia hostPath de MongoDB
sudo mkdir -p /data/mongodb
sudo chmod 777 /data/mongodb

# Pegar el comando generado por kubeadm token create:
sudo kubeadm join 172.31.20.216:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

✅ **Verificación de Nodos:**
* **Máquina donde se ejecuta:** `visons-master`
```bash
kubectl get nodes -o wide
```
*Salida esperada:*
```text
NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP     OS-IMAGE
visons-master            Ready    control-plane   10m   v1.29.x   172.31.20.216   Ubuntu 22.04 LTS
visons-worker-backend1   Ready    <none>          3m    v1.29.x   172.31.x.x     Ubuntu 22.04 LTS
visons-worker-backend2   Ready    <none>          3m    v1.29.x   172.31.x.x     Ubuntu 22.04 LTS
visons-worker-frontend   Ready    <none>          3m    v1.29.x   172.31.x.x     Ubuntu 22.04 LTS
visons-worker-mongodb    Ready    <none>          3m    v1.29.x   172.31.x.x     Ubuntu 22.04 LTS
```

---

## 🏷️ SECCIÓN 4: CRITERIO 1 — AISLAMIENTO DE NODOS CON LABELS Y NODESELECTOR

* **Máquina donde se ejecuta:** `visons-master`

```bash
# 1. Asignar etiquetas de rol a cada nodo:
kubectl label node visons-worker-frontend role=frontend --overwrite
kubectl label node visons-worker-backend1 role=backend1 --overwrite
kubectl label node visons-worker-backend2 role=backend2 --overwrite
kubectl label node visons-worker-mongodb role=mongodb --overwrite
```

✅ **Verificación del Criterio 1 (EVIDENCIA DE EVALUACIÓN):**
* **Máquina donde se ejecuta:** `visons-master`
```bash
kubectl get nodes --show-labels
```
*Salida esperada:*
Cada nodo debe mostrar su etiqueta:
* `visons-worker-frontend` con `role=frontend`
* `visons-worker-backend1` con `role=backend1`
* `visons-worker-backend2` con `role=backend2`
* `visons-worker-mongodb` con `role=mongodb`

> 📸 **Captura requerida para Informe (Criterio 1):** Tomar captura de pantalla de `kubectl get nodes --show-labels`.

---

## 🗄️ SECCIÓN 5: CRITERIO 3 (PARTE A) — CONFIGURACIÓN DE AMAZON RDS SQL SERVER

### Paso 5.1: Crear la Base de Datos RDS en AWS
* **Máquina donde se ejecuta:** AWS CloudShell o AWS Management Console:
  * **Motor:** Microsoft SQL Server (Edición: `Express Edition`).
  * **Identificador de BD:** `visonsdb`.
  * **Master Username:** `admin`.
  * **Master Password:** Tu contraseña (ej. `'diego1416'`).
  * **VPC:** La misma VPC por defecto donde residen tus EC2.
  * **Security Group:** Seleccionar únicamente **`sg-visons-rds`**.
  * **Acceso Público (Publicly Accessible):** **No**.

---

### Paso 5.2: Instalar herramienta sqlcmd y validar conectividad en Master
* **Máquina donde se ejecuta:** `visons-master`

```bash
# 1. Instalar la utilidad standalone oficial de Microsoft (go-sqlcmd):
sudo apt-get update -qq && sudo apt-get install -y -qq bzip2 curl netcat-traditional
curl -sSL "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.2/sqlcmd-linux-amd64.tar.bz2" | sudo tar -xj -C /usr/local/bin
sudo chmod +x /usr/local/bin/sqlcmd

# 2. Probar conectividad TCP al puerto 1433 de la RDS:
nc -zv visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com 1433
```

✅ **Verificación de RDS:**
*Salida esperada:*
`Connection to visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com 1433 port [tcp/ms-sql-s] succeeded!`

---

## 🚀 SECCIÓN 6: DESPLIEGUE DE LA PLATAFORMA EN KUBERNETES

* **Máquina donde se ejecuta:** `visons-master`

### Paso 6.1: Clonar el Repositorio Directo (Evita error de submódulo vacío)
```bash
cd ~
rm -rf kubernetes
git clone https://github.com/diegoECV/kubernetes.git
cd kubernetes
```

---

### Paso 6.2: Inyectar Variables en ConfigMaps y Secrets
```bash
# Configurar variables de tu sesión activa
RDS_ENDPOINT="visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com"
RDS_USER="admin"
RDS_PASSWORD='tu_password_rds'   # ← En comillas simples
ELASTIC_IP="52.20.37.223"        # ← IP pública de visons-master

# 1. Inyectar en ConfigMaps:
sed -i "s|r2dbc:mssql://sqlserver-service:1433/Visons|r2dbc:mssql://$RDS_ENDPOINT:1433/Visons|g" k8s/02-configmaps.yaml
sed -i "s|SPRING_R2DBC_USERNAME: \"sa\"|SPRING_R2DBC_USERNAME: \"$RDS_USER\"|g" k8s/02-configmaps.yaml
sed -i "s|SQL_SERVER: \"sqlserver-service\"|SQL_SERVER: \"$RDS_ENDPOINT\"|g" k8s/02-configmaps.yaml
sed -i "s|SQL_USER: \"sa\"|SQL_USER: \"$RDS_USER\"|g" k8s/02-configmaps.yaml
sed -i "s|FRONTEND_URL:.*|FRONTEND_URL: \"http://$ELASTIC_IP:30080\"|g" k8s/02-configmaps.yaml

# 2. Inyectar en Secrets (usando regex segura contra signos !):
sed -i "s|SPRING_R2DBC_PASSWORD:.*|SPRING_R2DBC_PASSWORD: \"$RDS_PASSWORD\"|g" k8s/01-secrets.yaml
sed -i "s|SQL_PASSWORD:.*|SQL_PASSWORD: \"$RDS_PASSWORD\"|g" k8s/01-secrets.yaml
```

---

### Paso 6.3: Aplicar Manifiestos en Orden Estricto
> ⚠️ **REGLA DE ORO:** Se aplica `k8s/databases/mongodb.yaml`. **NO** se aplica `sqlserver.yaml` porque SQL Server reside en Amazon RDS.

```bash
# 1. Namespace, Secretos y ConfigMaps
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-secrets.yaml
kubectl apply -f k8s/02-configmaps.yaml

# 2. Base de datos MongoDB en clúster
kubectl apply -f k8s/databases/mongodb.yaml

# 3. Backend 1 Transaccional (Spring Boot)
kubectl apply -f k8s/backend-transaccional/

# 4. Backend 2 Analítico (Python Flask)
kubectl apply -f k8s/backend-analitico/

# 5. Frontend Web (React + Nginx)
kubectl apply -f k8s/frontend-web/

# Esperar a que los pods alcancen 1/1 Running:
echo "Esperando arranque de pods..."
sleep 25
```

---

### Paso 6.4: Inyectar la IP Pública en los Archivos Estáticos del Frontend
```bash
# Reemplazar URLs de APIs en tiempo de ejecución en el pod:
kubectl exec -n visons-prod deployment/frontend-web -- sh -c \
  "sed -i 's|http://localhost:9090|http://$ELASTIC_IP:30090|g; s|http://localhost:5000|http://$ELASTIC_IP:30500|g; s|34.228.12.107|$ELASTIC_IP|g; s|54.234.91.155|$ELASTIC_IP|g; s|52.73.219.160|$ELASTIC_IP|g' /usr/share/nginx/html/assets/*.js"

# Verificar que la IP quedó grabada:
kubectl exec -n visons-prod deployment/frontend-web -- sh -c "grep -o '$ELASTIC_IP:30090' /usr/share/nginx/html/assets/*.js" | head -1
```

✅ **Verificación del Despliegue y Aislamiento de Nodos (Criterio 1):**
* **Máquina donde se ejecuta:** `visons-master`
```bash
kubectl get pods -n visons-prod -o wide
```
*Salida esperada:*
```text
NAME                                     READY   STATUS    RESTARTS   IP           NODE                     NOMINATED NODE
backend-analitico-xxxxxxxxxx-xxxxx       1/1     Running   0          10.244.3.x   visons-worker-backend2   <none>
backend-transaccional-xxxxxxxxxx-xxxxx   1/1     Running   0          10.244.2.x   visons-worker-backend1   <none>
frontend-web-xxxxxxxxxx-xxxxx            1/1     Running   0          10.244.1.x   visons-worker-frontend   <none>
mongodb-xxxxxxxxxx-xxxxx                  1/1     Running   0          10.244.4.x   visons-worker-mongodb    <none>
```
> 📸 **Captura requerida para Informe (Criterio 1):** Tomar captura de pantalla de `kubectl get pods -n visons-prod -o wide`.

---

## 🔄 SECCIÓN 7: CRITERIO 2 — CONECTIVIDAD INTERNA ENTRE BACKEND 1 Y BACKEND 2

* **Concepto Evaluado:** Los pods de microservicios no se comunican por IP efímera, sino mediante los Services de Kubernetes y el CoreDNS interno del clúster:
  * Backend 1 Service: `backend-transaccional-service.visons-prod.svc.cluster.local:9090`
  * Backend 2 Service: `backend-analitico-service.visons-prod.svc.cluster.local:5000`

---

### Paso 7.1: Prueba de Resolución DNS Interna
* **Máquina donde se ejecuta:** `visons-master`

```bash
# Comprobar resolución DNS del Backend 2 desde un contenedor temporal:
kubectl run dns-test -n visons-prod --rm -i --restart=Never --image=busybox:1.36 -- nslookup backend-analitico-service
```
*Salida esperada:*
```text
Server:    10.96.0.10
Address 1: 10.96.0.10 kube-dns.kube-system.svc.cluster.local

Name:      backend-analitico-service
Address 1: 10.10x.x.x backend-analitico-service.visons-prod.svc.cluster.local
```

---

### Paso 7.2: Prueba Real de Llamada HTTP Pod-a-Pod
* **Máquina donde se ejecuta:** `visons-master`

```bash
# 1. Llamar al Backend 2 (Python Flask) directamente desde el contenedor de Backend 1:
kubectl exec -n visons-prod deployment/backend-analitico -- python3 -c \
  "import urllib.request; resp = urllib.request.urlopen('http://backend-transaccional-service:9090/actuator/health'); print('Respuesta Backend1:', resp.read().decode())"

# 2. Llamar al Backend 2 por su nombre DNS de servicio interno:
kubectl run curl-test -n visons-prod --rm -i --restart=Never --image=curlimages/curl:8.5.0 -- \
  curl -s http://backend-analitico-service:5000/health
```

✅ **Verificación del Criterio 2 (EVIDENCIA DE EVALUACIÓN):**
*Salida esperada:*
* `Respuesta Backend1: {"status":"UP"}`
* `{"status":"healthy","service":"backend-analitico"}`

> 📸 **Captura requerida para Informe (Criterio 2):** Tomar captura de pantalla de la prueba pod-a-pod donde se aprecie la respuesta exitosa `{"status":"UP"}` llamando al nombre de servicio DNS.

---

## 🗄️ SECCIÓN 8: CRITERIO 3 (PARTE B) — PERSISTENCIA POLÍGLOTA Y POBLADO DE DATOS

* **Máquina donde se ejecuta:** `visons-master`

```bash
# Ejecutar el script automatizado de poblado e inicialización:
bash scripts/seed-databases.sh
```

*(Si deseas ejecutar el poblado paso a paso manualmente):*

### Paso 8.1: Poblado Manual de MongoDB (16 Colecciones)
```bash
curl -sSL https://raw.githubusercontent.com/diegoECV/FN1/main/database-p/init/Visons_mongodb_completo.js | \
  kubectl exec -i -n visons-prod deployment/mongodb -- mongosh -u admin -p admin123 --authenticationDatabase admin Visons
```

---

### Paso 8.2: Poblado Manual de Amazon RDS SQL Server (11 Tablas sin error FK)
```bash
curl -sSL https://raw.githubusercontent.com/diegoECV/FN1/main/database-p/init/Visons_sqlserver_completo.sql -o /tmp/Visons_sqlserver_completo.sql
sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -i /tmp/Visons_sqlserver_completo.sql
```

---

✅ **Verificación del Criterio 3 (EVIDENCIA DE EVALUACIÓN):**

```bash
# 1. Conteo de tablas en Amazon RDS SQL Server (Deben figurar 11 tablas con 10 filas cada una):
sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -d Visons -Q \
  "SELECT t.name AS Tabla, p.rows AS Total_Filas FROM sys.tables t JOIN sys.partitions p ON t.object_id = p.object_id WHERE p.index_id IN (0,1) AND t.name != 'schema_change' ORDER BY t.name;"

# 2. Conteo de colecciones en MongoDB:
kubectl exec -i -n visons-prod deployment/mongodb -- mongosh -u admin -p admin123 --authenticationDatabase admin Visons --eval \
  "db.getCollectionNames().forEach(c => print(c + ': ' + db[c].countDocuments()))"
```

*Salida esperada en RDS:*
```text
Tabla                                            Total_Filas
------------------------------------------------ -----------
ASSIGNMENTS                                               10
AUDIT_LOGS                                                10
BATCHES                                                   10
CERTIFICATES                                              10
CUSTOMS_DECLARATIONS                                      10
INVOICES                                                  10
ORDER_DETAILS                                             10
ORDERS                                                    10
PAYMENTS                                                  10
SHIPMENT_ITEMS                                            10
SHIPMENTS                                                 10
(11 rows affected)
```

> 📸 **Captura requerida para Informe (Criterio 3):**
> 1. Captura de la tabla de SQL Server con las 11 entidades y sus 10 filas.
> 2. Captura del conteo de documentos en MongoDB mostrando las colecciones `users`, `products` e `inspections`.

---

## 🌐 SECCIÓN 9: CRITERIO 4 — ENDPOINTS EXPUESTOS Y DOCUMENTADOS

* **Máquina donde se ejecuta:** `visons-master` o navegador web:

### Prueba 9.1: Login Real y Obtención de Token JWT
```bash
curl -s -X POST http://localhost:30090/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin@visons.com","password":"password123"}'
echo ""
```
*Salida esperada:*
```json
{"token":"eyJhbGciOiJIUzM4NCJ9...","username":"admin@visons.com","role":"ADMIN","expiresIn":36000}
```
> 📸 **Captura requerida:** Token JWT devuelto exitosamente en Postman o terminal.

---

### Prueba 9.2: Backend Analítico — Cálculo de KPIs en Vivo
```bash
curl -s http://localhost:30500/api/v1/analytics/dashboard/kpis | cut -c 1-135
echo ""
```
*Salida esperada:*
```json
{"data":{"calidad":{"tasa_aprobacion_pct":100.0,"total_inspecciones":10},"comercial":{"facturacion_total_usd":25860.0,"ordenes_pendien...
```
> 📸 **Captura requerida:** JSON de KPIs analíticos mostrando `facturacion_total_usd: 25860.0` y `total_inspecciones: 10`.

---

### Prueba 9.3: Swagger UI (Documentación Interactiva OpenAPI)
Abre en tu navegador:
👉 **`http://<MASTER_PUBLIC_IP>:30090/swagger-ui.html`**
> 📸 **Captura requerida:** Interfaz de Swagger cargada con los endpoints de Spring Boot (`/api/v1/orders`, `/api/v1/users`, etc.).

---

### Prueba 9.4: Frontend Web React
Abre en tu navegador:
👉 **`http://<MASTER_PUBLIC_IP>:30080`**
* **Usuario:** `admin@visons.com`
* **Contraseña:** `password123`
> 📸 **Captura requerida:** Pantalla del Dashboard de Visons con las tablas de órdenes y las métricas de exportación pobladas.

---

## 🛠️ SECCIÓN 10: TABLA DE TROUBLESHOOTING (LOS 9 PROBLEMAS PREVENIDOS POR DISEÑO)

| # | Problema Detectado Anteriormente | Causa Raíz Técnica | Prevención Blindada en este Manual |
|---|---|---|---|
| **1** | Submódulo `kubernetes` vacío al clonar | Clonar el monorepo `FN1` dejaba submódulos sin inicializar | Se clona directamente el repositorio oficial `diegoECV/kubernetes.git` (Sección 6.1). |
| **2** | Error de Bash `-bash: !: event not found` | Bash interpreta el signo `!` en contraseñas como expansión de historial | Se usan comillas simples `'...'` y reemplazos con comodines regex `.*` en `sed` (Sección 0 y 6.2). |
| **3** | MongoDB en estado `Pending` | El PVC intentaba aprovisionamiento dinámico de EBS inexistente | Se usa `hostPath: /data/mongodb` con permisos `777` en el nodo dedicado (Sección 3.2.D). |
| **4** | Spring Boot en `CrashLoopBackOff` | `livenessProbe` a `/actuator/info` daba 401 Unauthorized | Sonda configurada con `tcpSocket: port: 9090` + RAM pooled en Netty (Sección 6.3). |
| **5** | Timeout al puerto 10250 en `kubectl exec` | Falta de regla en Security Group entre Master y Workers | Puerto 10250 y Todo el Tráfico permitidos entre SGs desde la creación (Sección 1.2). |
| **6** | Bases de datos vacías (Login vacío, KPIs en 0) | RDS y Mongo inician sin esquema ni registros semilla | Script maestro `scripts/seed-databases.sh` que puebla 11 tablas y 16 colecciones (Sección 8). |
| **7** | Error FK en SQL Server (`Msg 547`) | `DBCC RESEED, 0` genera IDs desde 0 y rompe relaciones 1..10 | Uso de `SET IDENTITY_INSERT ON` y `NOCHECK CONSTRAINT all` durante la carga (Sección 8.2). |
| **8** | "La conexión ha caducado" en navegador | Falta de regla NodePort 30080 en Security Groups de AWS | Regla `TCP 30080` desde `0.0.0.0/0` abierta desde la fase de Security Groups (Sección 1.2). |
| **9** | Master no reconoce comando `sqlcmd` | Ubuntu EC2 no incluye cliente de SQL Server preinstalado | Instalación en caliente del binario standalone `go-sqlcmd` en `/usr/local/bin/sqlcmd` (Sección 5.2). |

---

## 📋 SECCIÓN 11: CHECKLIST DE ENTREGA PARA LA EVALUACIÓN (20/20)

| Criterio Evaluado | Comando de Demostración en Vivo | Evidencia / Captura Requerida |
|---|---|---|
| **Criterio 1: Nodos Aislados** | `kubectl get nodes --show-labels` y `kubectl get pods -n visons-prod -o wide` | Captura con los 4 pods en sus 4 worker nodes específicos. |
| **Criterio 2: Conectividad Interna** | `kubectl exec -n visons-prod deployment/backend-analitico -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://backend-transaccional-service:9090/actuator/health').read().decode())"` | Captura mostrando respuesta `{"status":"UP"}` usando DNS interno. |
| **Criterio 3: Persistencia Políglota** | `sqlcmd -S $RDS_ENDPOINT ... -Q "SELECT count(*) FROM ORDERS"` y comando de conteo en Mongo | Captura de las 11 tablas con 10 filas en RDS y 16 colecciones en Mongo. |
| **Criterio 4: Endpoints Expuestos** | `curl -X POST .../login` y `http://<IP>:30080` en navegador | Captura del Token JWT en Postman/Terminal y Dashboard Web funcional. |

---

## 🔍 SECCIÓN 12: REVISIÓN EN SECO (DRY RUN AUDIT)

Antes de entregar este manual, hemos realizado una auditoría exhaustiva comando por comando contra los archivos del repositorio:

1. **Auditoría de Manifiestos de Kubernetes:**
   - **Contradicción corregida:** En `k8s/databases/sqlserver.yaml` existía un despliegue de SQL Server local para Minikube. Se renombró a `sqlserver-in-cluster.yaml.disabled` y se aclaró en el manual que en AWS se aplica **únicamente** `mongodb.yaml`, ya que SQL Server corre de forma gestionada en Amazon RDS.
   - **Sincronización de Etiquetas:** Se actualizaron `frontend-web`, `backend-transaccional`, `backend-analitico` y `mongodb.yaml` para usar `nodeSelector: role: <frontend|backend1|backend2|mongodb>`, coincidiendo al 100% con los comandos de etiquetado del manual.
2. **Auditoría de Manejo de Contraseñas en Bash:**
   - Si una contraseña contiene signos como `!`, ejecutar `sed -i "s|PWD|$PASSWORD|g"` con comillas dobles en Bash causaría error `event not found`. En el manual se especificó el uso estricto de comodines regex y comillas simples `'...'` para asegurar que ningún comando falle por caracteres especiales.
3. **Auditoría de Dependencias de Red en AWS:**
   - Si se intentan crear Security Groups con reglas que referencian otros SGs que aún no existen, AWS CLI falla con `InvalidGroup.NotFound`. El manual resuelve esto mediante una creación en **dos fases** (fase 1: crear los 3 SGs vacíos; fase 2: aplicar las reglas cruzadas).
4. **Auditoría de Integridad Referencial en SQL Server:**
   - Se validó que el script `Visons_sqlserver_completo.sql` contenga `SET IDENTITY_INSERT ORDERS ON;` y `SET IDENTITY_INSERT SHIPMENTS ON;`, evitando el error histórico `Msg 547 (Foreign Key Constraint)` y asegurando la inserción exacta de las 10 filas por tabla.

# 📘 MANUAL MAESTRO DEFINITIVO DE DESPLIEGUE: PLATAFORMA VISONS S.A.C.
> **Guía Ejecutable Paso a Paso de Principio a Fin — Arquitectura 100% Real**  
> **Clúster Kubernetes (Exactamente 5 EC2) + Amazon RDS SQL Server + MongoDB**  
> **Repositorio Oficial:** `https://github.com/diegoECV/kubernetes.git`  
> **Autor:** Diego Centeno | **Proyecto:** Visons S.A.C.

---

## 🗺️ ÍNDICE DE EJECUCIÓN (ORDEN RIGUROSO)
1. **PASO 1:** Crear los 3 Security Groups (vacíos) ➔ luego sus reglas
2. **PASO 2:** Crear las 5 instancias EC2 (Master + 4 Workers)
3. **PASO 3:** Iniciar el Master (`kubeadm init` + CNI Flannel)
4. **PASO 4:** Unir los 4 Workers al Master (`kubeadm join`)
5. **PASO 5:** Ponerle etiqueta a cada Worker (`frontend`, `backend1`, `backend2`, `mongodb`)
6. **PASO 6:** Crear la RDS (`SQL Server` en Amazon RDS)
7. **PASO 7:** Desplegar los pods y llenar las bases de datos
8. **PASO 8:** Probar los endpoints (Postman / Swagger) y tomar capturas

---

## 📌 0. VARIABLES DE CONFIGURACIÓN GLOBAL
> Define estas variables al iniciar la sesión en una hoja de notas o cárgalas en la terminal. **IMPORTANTE:** Todas las contraseñas van entre comillas simples `'...'` para evitar que Bash las interprete como expansiones de historial si contienen signos como `!`.

```bash
# Variables del entorno AWS
export AWS_REGION="us-east-1"
export VPC_CIDR="172.31.0.0/16"
export PREFIX_LIST_EIC="com.amazonaws.us-east-1.ec2-instance-connect"

# Tu IP pública para acceso administrativo seguro:
export MY_IP="$(curl -s https://checkip.amazonaws.com)/32"

# Parámetros de Amazon RDS SQL Server:
export RDS_ENDPOINT="visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com"
export RDS_PORT="1433"
export RDS_USER="admin"
export RDS_PASSWORD='tu_password_rds'  # ← En comillas simples

# Parámetros del Master (completar tras lanzar las EC2):
export MASTER_PUBLIC_IP="52.20.37.223"   # ← IP pública de visons-master
export MASTER_PRIVATE_IP="172.31.20.216" # ← IP privada de visons-master
```

---

# 🛡️ PASO 1: CREAR 3 SECURITY GROUPS (VACÍOS) ➔ LUEGO SUS REGLAS
> **¿Por qué este orden?** Los Security Groups se crean primero **completamente vacíos** y luego se agregan las reglas. Esto es obligatorio porque se referencian entre sí como origen (Source SG), evitando errores de dependencia circular en AWS.

### 1.1 Crear los 3 Security Groups vacíos
* **Máquina donde se ejecuta:** AWS CloudShell o tu máquina local con AWS CLI:

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

### 1.2 Inyectar las Reglas de Entrada (Inbound Rules) referenciadas entre sí

#### A. Reglas para `sg-visons-master`
* **Máquina donde se ejecuta:** AWS CloudShell o AWS CLI:

```bash
# SSH (22) desde tu IP y desde EC2 Instance Connect
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 22 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 22 --prefix-list-id $(aws ec2 describe-managed-prefix-lists --filters "Name=prefix-list-name,Values=*ec2-instance-connect" --query "PrefixLists[0].PrefixListId" --output text)

# K8s API Server (6443) desde tu IP y desde los Workers
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 6443 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 6443 --source-group $SG_WORKERS_ID

# NodePorts públicos (30080 Frontend, 30090 Backend1, 30500 Backend2)
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30080 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30090 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30500 --cidr 0.0.0.0/0

# Monitoreo (30300 Grafana y 30091 Prometheus) solo desde tu IP
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30300 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol tcp --port 30091 --cidr $MY_IP

# Todo el tráfico desde los Workers (CNI Flannel VXLAN, Kubelet 10250, etcd)
aws ec2 authorize-security-group-ingress --group-id $SG_MASTER_ID --protocol all --source-group $SG_WORKERS_ID
```

#### B. Reglas para `sg-visons-workers`
* **Máquina donde se ejecuta:** AWS CloudShell o AWS CLI:

```bash
# SSH (22) desde tu IP y desde EC2 Instance Connect
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 22 --cidr $MY_IP
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 22 --prefix-list-id $(aws ec2 describe-managed-prefix-lists --filters "Name=prefix-list-name,Values=*ec2-instance-connect" --query "PrefixLists[0].PrefixListId" --output text)

# Kubelet API (10250) desde el Master (elimina timeouts de kubectl exec/logs)
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 10250 --source-group $SG_MASTER_ID

# Todo el tráfico desde el Master y entre Workers (comunicación pod-a-pod y Flannel)
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol all --source-group $SG_MASTER_ID
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol all --source-group $SG_WORKERS_ID

# Rango NodePort (30000-32767) dentro de la VPC para balanceo kube-proxy
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 30000-32767 --cidr $VPC_CIDR

# NodePort 30080 público directo para acceso Web
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 30080 --cidr 0.0.0.0/0

# MongoDB (27017) estricto: accesible ÚNICAMENTE dentro del Security Group de Workers (nunca público)
aws ec2 authorize-security-group-ingress --group-id $SG_WORKERS_ID --protocol tcp --port 27017 --source-group $SG_WORKERS_ID
```

#### C. Reglas para `sg-visons-rds`
* **Máquina donde se ejecuta:** AWS CloudShell o AWS CLI:

```bash
# SQL Server (1433) accesible ÚNICAMENTE desde el Master y desde los Workers
aws ec2 authorize-security-group-ingress --group-id $SG_RDS_ID --protocol tcp --port 1433 --source-group $SG_MASTER_ID
aws ec2 authorize-security-group-ingress --group-id $SG_RDS_ID --protocol tcp --port 1433 --source-group $SG_WORKERS_ID
```

> **Egress:** Los tres Security Groups conservan la regla de salida por defecto (`0.0.0.0/0`).

✅ **Verificación del Paso 1:**
```bash
aws ec2 describe-security-groups --group-ids $SG_MASTER_ID $SG_WORKERS_ID $SG_RDS_ID --query "SecurityGroups[*].[GroupName,GroupId]" --output table
```
*Salida esperada:* Tabla con los 3 grupos creados y asociados a la VPC.

---

# 💻 PASO 2: CREAR LAS 5 INSTANCIAS EC2 (MASTER + 4 WORKERS)
> Lanza **exactamente 5 instancias** en la consola de AWS EC2 bajo **Ubuntu 22.04 LTS**:

| # | Nombre de la Instancia | Rol en Kubernetes | Tipo | Disco | Security Group Asignado |
|---|---|---|---|---|---|
| **1** | **`visons-master`** | Control-Plane | **t3.medium** (2 vCPU, 4GB) | 20 GB gp3 | `sg-visons-master` |
| **2** | **`visons-worker-frontend`** | Worker Frontend | **t3.small** / **t3.medium** | 15 GB gp3 | `sg-visons-workers` |
| **3** | **`visons-worker-backend1`** | Worker Backend 1 (Java) | **t3.medium** (2 vCPU, 4GB) | 20 GB gp3 | `sg-visons-workers` |
| **4** | **`visons-worker-backend2`** | Worker Backend 2 (Python) | **t3.medium** (2 vCPU, 4GB) | 20 GB gp3 | `sg-visons-workers` |
| **5** | **`visons-worker-mongodb`** | Worker MongoDB | **t3.medium** (2 vCPU, 4GB) | 20 GB gp3 | `sg-visons-workers` |

---

### 2.1 Preparación en CADA UNA de las 5 Instancias
* **Máquina donde se ejecuta:** Conéctate por **EC2 Instance Connect** y ejecuta en **CADA UNA** de las 5 máquinas:

```bash
# 1. Desactivar Swap (Obligatorio para Kubernetes)
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# 2. Configurar módulos de red del kernel
cat << 'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# 3. Parámetros sysctl
cat << 'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# 4. Instalar containerd con SystemdCgroup
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

# 5. Instalar kubelet, kubeadm y kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

✅ **Verificación del Paso 2:**
```bash
swapon --show
sudo systemctl is-active containerd kubelet
```
*Salida esperada:* `swapon --show` devuelve vacío y ambos servicios responden `active`.

---

# 🚀 PASO 3: INICIAR EL MASTER (`KUBEADM INIT`)
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

# 5. Generar y mostrar el comando join para los workers:
sudo kubeadm token create --print-join-command
```

✅ **Verificación del Paso 3:**
```bash
kubectl get nodes
```
*Salida esperada:* `visons-master` en estado `Ready`.

---

# 🔗 PASO 4: UNIR LOS 4 WORKERS AL MASTER (`KUBEADM JOIN`)
> Conéctate a cada worker por **EC2 Instance Connect** y ejecuta su bloque:

### 4.1 En la máquina: `visons-worker-frontend`
```bash
sudo hostnamectl set-hostname visons-worker-frontend
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Pegar el comando generado por kubeadm token create:
sudo kubeadm join 172.31.20.216:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

### 4.2 En la máquina: `visons-worker-backend1`
```bash
sudo hostnamectl set-hostname visons-worker-backend1
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Pegar el comando generado por kubeadm token create:
sudo kubeadm join 172.31.20.216:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

### 4.3 En la máquina: `visons-worker-backend2`
```bash
sudo hostnamectl set-hostname visons-worker-backend2
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Pegar el comando generado por kubeadm token create:
sudo kubeadm join 172.31.20.216:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

### 4.4 En la máquina: `visons-worker-mongodb`
```bash
sudo hostnamectl set-hostname visons-worker-mongodb
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Crear carpeta con permisos para persistencia hostPath de MongoDB
sudo mkdir -p /data/mongodb
sudo chmod 777 /data/mongodb

# Pegar el comando generado por kubeadm token create:
sudo kubeadm join 172.31.20.216:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

✅ **Verificación del Paso 4:**
* **Máquina donde se ejecuta:** `visons-master`
```bash
kubectl get nodes -o wide
```
*Salida esperada:*
```text
NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP
visons-master            Ready    control-plane   10m   v1.29.x   172.31.20.216
visons-worker-backend1   Ready    <none>          3m    v1.29.x   172.31.x.x
visons-worker-backend2   Ready    <none>          3m    v1.29.x   172.31.x.x
visons-worker-frontend   Ready    <none>          3m    v1.29.x   172.31.x.x
visons-worker-mongodb    Ready    <none>          3m    v1.29.x   172.31.x.x
```

---

# 🏷️ PASO 5: PONERLE ETIQUETA A CADA WORKER (`CRITERIO 1`)
* **Máquina donde se ejecuta:** `visons-master`

```bash
# Asignar la etiqueta de rol dedicada a cada nodo:
kubectl label node visons-worker-frontend role=frontend --overwrite
kubectl label node visons-worker-backend1 role=backend1 --overwrite
kubectl label node visons-worker-backend2 role=backend2 --overwrite
kubectl label node visons-worker-mongodb role=mongodb --overwrite
```

✅ **Verificación del Paso 5 (EVIDENCIA DE EVALUACIÓN - CRITERIO 1):**
* **Máquina donde se ejecuta:** `visons-master`
```bash
kubectl get nodes --show-labels
```
*Salida esperada:* Cada nodo muestra su etiqueta `role=frontend`, `role=backend1`, `role=backend2`, `role=mongodb`.

> 📸 **Captura requerida (Criterio 1):** Tomar captura de pantalla de `kubectl get nodes --show-labels`.

---

# 🗄️ PASO 6: CREAR LA RDS (`SQL SERVER`)
* **Máquina donde se ejecuta:** Consola de AWS (RDS) o AWS CloudShell:
  * **Motor:** Microsoft SQL Server (`Express Edition`).
  * **Identificador de BD:** `visonsdb`.
  * **Master Username:** `admin`.
  * **Master Password:** Tu contraseña (ej. `'diego1416'`).
  * **VPC:** La misma VPC por defecto de tus EC2.
  * **Security Group:** Seleccionar únicamente **`sg-visons-rds`**.
  * **Acceso Público (Publicly Accessible):** **No**.

---

### 6.1 Instalar herramienta sqlcmd y validar conectividad en Master
* **Máquina donde se ejecuta:** `visons-master`

```bash
# 1. Instalar la utilidad standalone oficial de Microsoft (go-sqlcmd):
sudo apt-get update -qq && sudo apt-get install -y -qq bzip2 curl netcat-traditional
curl -sSL "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.2/sqlcmd-linux-amd64.tar.bz2" | sudo tar -xj -C /usr/local/bin
sudo chmod +x /usr/local/bin/sqlcmd

# 2. Probar conectividad TCP al puerto 1433 de la RDS:
nc -zv visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com 1433
```

✅ **Verificación del Paso 6:**
*Salida esperada:*
`Connection to visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com 1433 port [tcp/ms-sql-s] succeeded!`

---

# 📦 PASO 7: DESPLEGAR LOS PODS Y LLENAR LAS BASES DE DATOS
* **Máquina donde se ejecuta:** `visons-master`

### 7.1 Clonar el Repositorio Directo (Evita error de submódulo)
```bash
cd ~
rm -rf kubernetes
git clone https://github.com/diegoECV/kubernetes.git
cd kubernetes
```

---

### 7.2 Inyectar Variables en ConfigMaps y Secrets
```bash
RDS_ENDPOINT="visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com"
RDS_USER="admin"
RDS_PASSWORD='tu_password_rds'   # ← En comillas simples
ELASTIC_IP="52.20.37.223"        # ← Tu IP pública activa de visons-master

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

### 7.3 Desplegar Manifiestos de Kubernetes
> ⚠️ **REGLA:** Se aplica `mongodb.yaml`. **NO** se aplica `sqlserver.yaml` porque SQL Server corre en Amazon RDS.

```bash
# 1. Namespace, Secretos y ConfigMaps
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-secrets.yaml
kubectl apply -f k8s/02-configmaps.yaml

# 2. MongoDB
kubectl apply -f k8s/databases/mongodb.yaml

# 3. Backend 1 Transaccional
kubectl apply -f k8s/backend-transaccional/

# 4. Backend 2 Analítico
kubectl apply -f k8s/backend-analitico/

# 5. Frontend Web
kubectl apply -f k8s/frontend-web/

# Esperar 25s a que los pods alcancen 1/1 Running
sleep 25
```

---

### 7.4 Inyectar la IP Pública en el Frontend
```bash
kubectl exec -n visons-prod deployment/frontend-web -- sh -c \
  "sed -i 's|http://localhost:9090|http://$ELASTIC_IP:30090|g; s|http://localhost:5000|http://$ELASTIC_IP:30500|g; s|34.228.12.107|$ELASTIC_IP|g; s|54.234.91.155|$ELASTIC_IP|g; s|52.73.219.160|$ELASTIC_IP|g' /usr/share/nginx/html/assets/*.js"
```

---

### 7.5 Llenar las Bases de Datos (MongoDB y Amazon RDS SQL Server)
```bash
# Ejecutar el script automatizado que puebla ambas bases con validación:
bash scripts/seed-databases.sh
```

*(O de forma individual):*
```bash
# A. Poblar MongoDB:
curl -sSL https://raw.githubusercontent.com/diegoECV/FN1/main/database-p/init/Visons_mongodb_completo.js | \
  kubectl exec -i -n visons-prod deployment/mongodb -- mongosh -u admin -p admin123 --authenticationDatabase admin Visons

# B. Poblar RDS SQL Server:
curl -sSL https://raw.githubusercontent.com/diegoECV/FN1/main/database-p/init/Visons_sqlserver_completo.sql -o /tmp/Visons_sqlserver_completo.sql
sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -i /tmp/Visons_sqlserver_completo.sql
```

---

### 7.6 Probar Conectividad Interna entre Backend 1 y Backend 2 (`CRITERIO 2`)
```bash
# 1. DNS interno de K8s:
kubectl run dns-test -n visons-prod --rm -i --restart=Never --image=busybox:1.36 -- nslookup backend-analitico-service

# 2. Llamada HTTP pod-a-pod:
kubectl exec -n visons-prod deployment/backend-analitico -- python3 -c \
  "import urllib.request; resp = urllib.request.urlopen('http://backend-transaccional-service:9090/actuator/health'); print('Respuesta Backend1:', resp.read().decode())"
```

✅ **Verificación del Paso 7 (EVIDENCIA DE EVALUACIÓN - CRITERIO 1, 2 Y 3):**
* **Máquina donde se ejecuta:** `visons-master`

```bash
# 1. Pods en sus nodos asignados:
kubectl get pods -n visons-prod -o wide

# 2. Conteo de tablas en RDS SQL Server (11 tablas con 10 filas cada una):
sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -d Visons -Q \
  "SELECT t.name AS Tabla, p.rows AS Total_Filas FROM sys.tables t JOIN sys.partitions p ON t.object_id = p.object_id WHERE p.index_id IN (0,1) AND t.name != 'schema_change' ORDER BY t.name;"
```

> 📸 **Capturas requeridas:**
> 1. `kubectl get pods -n visons-prod -o wide` con los 4 pods `1/1 Running` en sus 4 worker nodes.
> 2. Respuesta pod-a-pod `{"status":"UP"}` llamando al servicio interno.
> 3. Tabla con las 11 entidades y sus 10 filas en SQL Server.

---

# 🎯 PASO 8: PROBAR LOS ENDPOINTS (POSTMAN / SWAGGER) Y TOMAR CAPTURAS (`CRITERIO 4`)

### 8.1 Prueba de Login JWT (Spring Boot)
* **Máquina:** Postman o terminal del Master:
  * **Método:** `POST`
  * **URL:** `http://<MASTER_PUBLIC_IP>:30090/api/v1/auth/login`
  * **Headers:** `Content-Type: application/json`
  * **Body (raw JSON):**
    ```json
    {
      "username": "admin@visons.com",
      "password": "password123"
    }
    ```
* **En terminal:**
```bash
curl -s -X POST http://localhost:30090/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin@visons.com","password":"password123"}'
echo ""
```
> 📸 **Captura requerida:** Token JWT devuelto exitosamente en Postman o terminal.

---

### 8.2 Prueba de KPIs Analíticos (Python Flask)
* **Máquina:** Postman o terminal del Master:
  * **Método:** `GET`
  * **URL:** `http://<MASTER_PUBLIC_IP>:30500/api/v1/analytics/dashboard/kpis`
* **En terminal:**
```bash
curl -s http://localhost:30500/api/v1/analytics/dashboard/kpis | cut -c 1-135
echo ""
```
> 📸 **Captura requerida:** JSON con `facturacion_total_usd: 25860.0` y `total_inspecciones: 10`.

---

### 8.3 Prueba de Swagger UI (Documentación OpenAPI)
* **Máquina:** Navegador Web:
  * **URL:** `http://<MASTER_PUBLIC_IP>:30090/swagger-ui.html`
> 📸 **Captura requerida:** Interfaz interactiva de Swagger con los endpoints de Spring Boot.

---

### 8.4 Prueba de Frontend Web React
* **Máquina:** Navegador Web:
  * **URL:** `http://<MASTER_PUBLIC_IP>:30080`
  * **Usuario:** `admin@visons.com`
  * **Contraseña:** `password123`
> 📸 **Captura requerida:** Pantalla del Dashboard de Visons con las tablas y métricas cargadas.

---

## 🛠️ APÉNDICE A: TABLA DE TROUBLESHOOTING (LOS 9 PROBLEMAS PREVENIDOS)

| # | Problema Anterior | Causa Técnica | Prevención en este Manual |
|---|---|---|---|
| **1** | Submódulo vacío al clonar | Clonar monorepo `FN1` dejaba submódulos vacíos | Clonar directo `https://github.com/diegoECV/kubernetes.git` (Paso 7.1). |
| **2** | Error `-bash: !: event not found` | Bash interpreta `!` como historial | Uso de comillas simples `'...'` y comodines regex en `sed` (Paso 0 y 7.2). |
| **3** | MongoDB en `Pending` | Falta de StorageClass para PVC dinámico | Uso de `hostPath: /data/mongodb` con permisos 777 en worker dedicado (Paso 4.4). |
| **4** | Spring Boot en `CrashLoop` | Sonda a `/actuator/info` daba 401 | Sonda configurada con `tcpSocket: port: 9090` + RAM pooled (Paso 7.3). |
| **5** | Timeout al puerto 10250 | Puerto 10250 bloqueado entre instancias | Regla 10250 y Todo el Tráfico entre SGs desde el inicio (Paso 1.2). |
| **6** | Bases de datos vacías | RDS y Mongo inician vírgenes | Script de poblado `scripts/seed-databases.sh` (Paso 7.5). |
| **7** | Error FK en SQL Server (`Msg 547`) | `DBCC RESEED, 0` generaba IDs desde 0 | `SET IDENTITY_INSERT ON` + `NOCHECK CONSTRAINT all` (Paso 7.5). |
| **8** | "La conexión ha caducado" | Puerto NodePort 30080 cerrado en AWS | Regla `TCP 30080` a `0.0.0.0/0` en SGs desde el inicio (Paso 1.2). |
| **9** | Master no tiene `sqlcmd` | Ubuntu EC2 no incluye cliente de SQL | Instalación de `go-sqlcmd` en `/usr/local/bin/sqlcmd` (Paso 6.1). |

---

## 📋 APÉNDICE B: CHECKLIST DE ENTREGA PARA EVALUACIÓN (20/20)

| Criterio Evaluado | Comando de Demostración en Vivo | Evidencia / Captura Requerida |
|---|---|---|
| **Criterio 1: Nodos Aislados** | `kubectl get nodes --show-labels` y `kubectl get pods -n visons-prod -o wide` | Captura con los 4 pods en sus 4 worker nodes específicos. |
| **Criterio 2: Conectividad Interna** | `kubectl exec -n visons-prod deployment/backend-analitico -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://backend-transaccional-service:9090/actuator/health').read().decode())"` | Captura mostrando respuesta `{"status":"UP"}` usando DNS interno. |
| **Criterio 3: Persistencia Políglota** | `sqlcmd -S $RDS_ENDPOINT ... -Q "SELECT count(*) FROM ORDERS"` y conteo en Mongo | Captura de las 11 tablas con 10 filas en RDS y 16 colecciones en Mongo. |
| **Criterio 4: Endpoints Expuestos** | `curl -X POST .../login` y `http://<IP>:30080` en navegador | Captura del Token JWT en Postman y Dashboard Web funcional. |

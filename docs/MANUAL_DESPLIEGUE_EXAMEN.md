# 📘 MANUAL MAESTRO DEFINITIVO DE DESPLIEGUE: PLATAFORMA VISONS S.A.C.
> **Guía Ejecutable Paso a Paso de Principio a Fin — 100% Consola Web de AWS + EC2 Instance Connect**  
> **Clúster Kubernetes (Exactamente 5 EC2) + Amazon RDS SQL Server + MongoDB**  
> **Repositorio Oficial:** `https://github.com/diegoECV/kubernetes.git`  
> **Autor:** Diego Centeno | **Proyecto:** Visons S.A.C.

---

## 🗺️ ÍNDICE DE EJECUCIÓN (ORDEN RIGUROSO)
1. **PASO 1:** Crear los 3 Security Groups (vacíos) ➔ luego sus reglas (Consola Web AWS)
2. **PASO 2:** Crear las 5 instancias EC2 (Master + 4 Workers) (Consola Web AWS + Script Base)
3. **PASO 3:** Iniciar el Master (`kubeadm init` + CNI Flannel)
4. **PASO 4:** Unir los 4 Workers al Master (`kubeadm join`)
5. **PASO 5:** Ponerle etiqueta a cada Worker (`frontend`, `backend1`, `backend2`, `mongodb`)
6. **PASO 6:** Crear la RDS (`SQL Server Express` en Consola Web AWS)
7. **PASO 7:** Desplegar los pods y llenar las bases de datos
8. **PASO 8:** Probar los endpoints (Postman / Swagger / Web) y tomar capturas

---

# 🛡️ PASO 1: CREAR 3 SECURITY GROUPS (VACÍOS) ➔ LUEGO SUS REGLAS

> ⚠️ **¿Por qué hacerlo en 2 fases en la Consola Web?**  
> Si intentas crear un Security Group agregando reglas que apunten a los otros grupos, AWS no te dejará porque los otros grupos aún no existen en tu lista.  
> Por eso, primero creamos los **3 Security Groups completamente vacíos**, y luego entramos a cada uno a agregarles sus reglas de entrada.

---

### 1.1 Crear los 3 Security Groups vacíos en la Consola Web de AWS
* **Dónde se hace:** En tu navegador web, entra a la **Consola de AWS**:
  1. En la barra de búsqueda superior escribe **EC2** y entra al servicio.
  2. En el menú lateral izquierdo, baja hasta la sección **Network & Security** (Red y seguridad) y haz clic en **Security Groups** (Grupos de seguridad).
  3. Haz clic en el botón naranja **"Create security group"** (Crear grupo de seguridad) para cada uno de los siguientes 3 grupos:

#### 🔹 Grupo 1: Para el Master
> ⚠️ **Nota de AWS:** El nombre **no puede empezar con `sg-`** (porque AWS reserva ese prefijo para sus IDs). Por eso colocamos `-sg` al final:
* **Security group name:** `visons-master-sg`
* **Description:** `Security Group para visons-master control-plane` *(la descripción es obligatoria)*
* **VPC:** Deja seleccionada tu **VPC por defecto** (Default VPC).
* **Inbound rules:** Déjalas **completamente vacías** por ahora.
* **Outbound rules:** Deja la regla por defecto (`All traffic / 0.0.0.0/0`).
* Haz clic en **Create security group**.

#### 🔹 Grupo 2: Para los 4 Workers
* Haz clic nuevamente en **Create security group**:
* **Security group name:** `visons-workers-sg`
* **Description:** `Security Group unificado para los 4 worker nodes de visons`
* **VPC:** La misma **VPC por defecto**.
* **Inbound rules:** Déjalas **completamente vacías**.
* Haz clic en **Create security group**.

#### 🔹 Grupo 3: Para la base de datos Amazon RDS
* Haz clic nuevamente en **Create security group**:
* **Security group name:** `visons-rds-sg`
* **Description:** `Security Group exclusivo para Amazon RDS SQL Server`
* **VPC:** La misma **VPC por defecto**.
* **Inbound rules:** Déjalas **completamente vacías**.
* Haz clic en **Create security group**.

---

### 1.2 Agregar las Reglas de Entrada (Inbound Rules) en la Consola Web

Regresa a la lista de **Security Groups** en la consola de EC2 y edita las reglas de cada uno:

---

#### 🅰️ Reglas para `visons-master-sg`
1. Selecciona **`visons-master-sg`** en la lista.
2. Abajo, en la pestaña **Inbound rules** (Reglas de entrada), haz clic en **Edit inbound rules** (Editar reglas de entrada).
3. Haz clic en **Add rule** (Agregar regla) para cada una de las siguientes filas:

| Tipo (Type) | Protocolo | Puerto (Port) | Origen (Source) | Valor del Origen | Descripción |
|---|---|---|---|---|---|
| **SSH** | TCP | `22` | **Anywhere-IPv4** | `0.0.0.0/0` | Conexión SSH y EC2 Instance Connect |
| **Custom TCP** | TCP | `6443` | **Custom** | Buscar y seleccionar **`visons-workers-sg`** | K8s API Server para los Workers |
| **Custom TCP** | TCP | `6443` | **Anywhere-IPv4** | `0.0.0.0/0` | K8s API Server para administración |
| **Custom TCP** | TCP | `30080` | **Anywhere-IPv4** | `0.0.0.0/0` | Acceso Web Frontend React |
| **Custom TCP** | TCP | `30090` | **Anywhere-IPv4** | `0.0.0.0/0` | API Backend 1 Spring Boot |
| **Custom TCP** | TCP | `30500` | **Anywhere-IPv4** | `0.0.0.0/0` | API Backend 2 Python Flask |
| **All traffic** | ALL | ALL | **Custom** | Buscar y seleccionar **`visons-workers-sg`** | CNI Flannel (VXLAN 8472) y comunicación K8s |

4. Haz clic en el botón naranja **Save rules** (Guardar reglas).

---

#### 🅱️ Reglas para `visons-workers-sg`
1. Selecciona **`visons-workers-sg`** en la lista.
2. En la pestaña **Inbound rules**, haz clic en **Edit inbound rules**.
3. Haz clic en **Add rule** para cada una de estas **4 filas limpias** (evita duplicados y errores de guardado):

| Tipo (Type) | Protocolo | Puerto (Port) | Origen (Source) | Valor del Origen | Descripción |
|---|---|---|---|---|---|
| **SSH** | TCP | `22` | **Anywhere-IPv4** | `0.0.0.0/0` | Conexión SSH y EC2 Instance Connect |
| **All traffic** | ALL | ALL | **Custom** | Buscar y seleccionar **`visons-master-sg`** | Todo el tráfico desde el Master (incluye Kubelet 10250) |
| **All traffic** | ALL | ALL | **Custom** | Buscar y seleccionar **`visons-workers-sg`** | Tráfico inter-workers (incluye MongoDB 27017 y Flannel) |
| **Custom TCP** | TCP | `30000-32767` | **Anywhere-IPv4** | `0.0.0.0/0` | Rango NodePorts K8s (Frontend 30080, Backend 30090, 30500) |

4. Haz clic en **Save rules**.

---

#### 🅲️ Reglas para `visons-rds-sg`
1. Selecciona **`visons-rds-sg`** en la lista.
2. En la pestaña **Inbound rules**, haz clic en **Edit inbound rules**.
3. Haz clic en **Add rule** para cada una de las siguientes filas:

| Tipo (Type) | Protocolo | Puerto (Port) | Origen (Source) | Valor del Origen | Descripción |
|---|---|---|---|---|---|
| **MS SQL** | TCP | `1433` | **Custom** | Buscar y seleccionar **`visons-master-sg`** | Acceso desde Master para `sqlcmd` y pruebas |
| **MS SQL** | TCP | `1433` | **Custom** | Buscar y seleccionar **`visons-workers-sg`** | Conexión R2DBC desde Backend 1 y Backend 2 |

4. Haz clic en **Save rules**.

---

# 💻 PASO 2: CREAR LAS 5 INSTANCIAS EC2 (MASTER + 4 WORKERS)

### 2.1 Lanzar las 5 Instancias en la Consola Web de AWS
* **Dónde se hace:** En la **Consola de AWS** ➔ Servicio **EC2** ➔ **Instances** (Instancias) ➔ botón naranja **Launch instances** (Lanzar instancias).

Crea las **5 instancias** con la siguiente configuración:

| # | Name (Nombre) | Rol K8s | AMI (Sistema Operativo) | Instance type | Disco (Storage) | Security Group a seleccionar |
|---|---|---|---|---|---|---|
| **1** | **`visons-master`** | Control-Plane | **Ubuntu Server 22.04 LTS** (x86) | **`t3.medium`** (2 vCPU, 4 GiB) | **20 GiB** gp3 | Seleccionar **`visons-master-sg`** |
| **2** | **`visons-worker-frontend`** | Worker Frontend | **Ubuntu Server 22.04 LTS** (x86) | **`t3.medium`** (2 vCPU, 4 GiB) | **20 GiB** gp3 | Seleccionar **`visons-workers-sg`** |
| **3** | **`visons-worker-backend1`** | Worker Backend 1 | **Ubuntu Server 22.04 LTS** (x86) | **`t3.medium`** (2 vCPU, 4 GiB) | **20 GiB** gp3 | Seleccionar **`visons-workers-sg`** |
| **4** | **`visons-worker-backend2`** | Worker Backend 2 | **Ubuntu Server 22.04 LTS** (x86) | **`t3.medium`** (2 vCPU, 4 GiB) | **20 GiB** gp3 | Seleccionar **`visons-workers-sg`** |
| **5** | **`visons-worker-mongodb`** | Worker MongoDB | **Ubuntu Server 22.04 LTS** (x86) | **`t3.medium`** (2 vCPU, 4 GiB) | **20 GiB** gp3 | Seleccionar **`visons-workers-sg`** |

> 📌 **Detalles clave al crear cada instancia en la pantalla de AWS:**
> 1. **Application and OS Images:** Elige el logo de **Ubuntu**, y en el desplegable verifica que diga **Ubuntu Server 22.04 LTS (HVM), SSD Volume Type** (64-bit x86).
> 2. **Instance type:** Elige **`t3.medium`** (necesita al menos 2 vCPUs para que Kubernetes kubeadm no de error).
> 3. **Key pair (login):** Selecciona tu par de claves existente (ej. `vockey` o tu llave `.pem`).
> 4. **Network settings (Configuración de red):** Haz clic en **Edit** (Editar):
>    - **Auto-assign public IP:** Asegúrate de que esté en **Enable** (Habilitar) para tener IP pública.
>    - **Firewall (security groups):** Marca la opción **"Select existing security group"** (Seleccionar grupo de seguridad existente).
>    - Para el Master marca `visons-master-sg`. Para los 4 Workers marca `visons-workers-sg`.
> 5. **Configure storage (Almacenamiento):** Cambia el tamaño de `8 GiB` a **`20 GiB`** tipo **gp3**.
> 6. Haz clic en **Launch instance** (Lanzar instancia).

---

### 2.2 Preparación e Instalación Base en CADA UNA de las 5 Instancias
* **Cómo conectarte a cada una:**
  1. En la lista de instancias de EC2, selecciona la instancia (ej. `visons-master`).
  2. Haz clic en el botón **"Connect"** (Conectar) en la esquina superior derecha.
  3. En la pestaña **"EC2 Instance Connect"**, deja el usuario `ubuntu` y haz clic en **"Connect"**. Se abrirá una terminal web directamente en tu navegador.
  4. Copia y pega el siguiente bloque completo y presiona Enter:

* **Máquina donde se ejecuta:** Ejecutar este **mismo bloque** en **CADA UNA DE LAS 5 INSTANCIAS** (`visons-master`, `visons-worker-frontend`, `visons-worker-backend1`, `visons-worker-backend2`, `visons-worker-mongodb`):

```bash
# 1. Desactivar Swap (Obligatorio para Kubernetes)
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# 2. Configurar módulos de red del kernel para Kubernetes
cat << 'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# 3. Parámetros sysctl requeridos por iptables y bridge
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

# 5. Instalar kubelet, kubeadm y kubectl v1.29
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable --now kubelet
```

✅ **Verificación del Paso 2 (en cada una):**
```bash
swapon --show
sudo systemctl is-active containerd kubelet
```
*Salida esperada:* `swapon --show` no devuelve nada (swap apagado) y el comando responde `active` para ambos servicios.

---

# 🚀 PASO 3: INICIAR EL MASTER (`KUBEADM INIT`)
* **Máquina donde se ejecuta:** Terminal de **`visons-master`** (vía EC2 Instance Connect):

```bash
# 1. Fijar hostname del Master
sudo hostnamectl set-hostname visons-master
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# 2. Inicializar el clúster con la red pod CIDR de Flannel (10.244.0.0/16)
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# 3. Configurar kubectl para el usuario ubuntu
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 4. Desplegar el plugin de red CNI Flannel
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 5. Imprimir el comando kubeadm join que usaremos en los 4 workers:
sudo kubeadm token create --print-join-command
```

> 📌 **Copia el comando `kubeadm join ...` que apareció en la última línea.** Lo necesitarás en el Paso 4.

✅ **Verificación del Paso 3:**
```bash
kubectl get nodes
```
*Salida esperada:*
```text
NAME            STATUS   ROLES           AGE   VERSION
visons-master   Ready    control-plane   1m    v1.29.x
```

---

# 🔗 PASO 4: UNIR LOS 4 WORKERS AL MASTER (`KUBEADM JOIN`)
> Conéctate a cada worker mediante **EC2 Instance Connect** y ejecuta su respectivo bloque de comandos:

---

### 4.1 En la máquina: `visons-worker-frontend`
```bash
sudo hostnamectl set-hostname visons-worker-frontend
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Ejecutar el comando join con sudo (usa el que te generó tu master):
sudo kubeadm join <IP_PRIVADA_MASTER>:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

### 4.2 En la máquina: `visons-worker-backend1`
```bash
sudo hostnamectl set-hostname visons-worker-backend1
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Ejecutar el comando join con sudo:
sudo kubeadm join <IP_PRIVADA_MASTER>:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

### 4.3 En la máquina: `visons-worker-backend2`
```bash
sudo hostnamectl set-hostname visons-worker-backend2
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Ejecutar el comando join con sudo:
sudo kubeadm join <IP_PRIVADA_MASTER>:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

### 4.4 En la máquina: `visons-worker-mongodb`
> ⚠️ **Atención:** En este nodo se crea la carpeta persistente `/data/mongodb` para que MongoDB nunca se quede en `Pending`.

```bash
sudo hostnamectl set-hostname visons-worker-mongodb
sudo sed -i 's/preserve_hostname: false/preserve_hostname: true/' /etc/cloud/cloud.cfg 2>/dev/null || true

# Crear la carpeta de datos persistente con permisos completos:
sudo mkdir -p /data/mongodb
sudo chmod 777 /data/mongodb

# Ejecutar el comando join con sudo:
sudo kubeadm join <IP_PRIVADA_MASTER>:6443 --token <TU_TOKEN> --discovery-token-ca-cert-hash sha256:<TU_HASH>
```

---

✅ **Verificación del Paso 4:**
* **Máquina donde se ejecuta:** Terminal de **`visons-master`**
```bash
kubectl get nodes -o wide
```
*Salida esperada (los 5 nodos en estado `Ready`):*
```text
NAME                     STATUS   ROLES           AGE   VERSION   INTERNAL-IP
visons-master            Ready    control-plane   10m   v1.29.x   172.31.x.x
visons-worker-backend1   Ready    <none>          2m    v1.29.x   172.31.x.x
visons-worker-backend2   Ready    <none>          2m    v1.29.x   172.31.x.x
visons-worker-frontend   Ready    <none>          2m    v1.29.x   172.31.x.x
visons-worker-mongodb    Ready    <none>          2m    v1.29.x   172.31.x.x
```

---

# 🏷️ PASO 5: PONERLE ETIQUETA A CADA WORKER (`CRITERIO 1`)
* **Máquina donde se ejecuta:** Terminal de **`visons-master`**

```bash
# Asignar la etiqueta de rol dedicada a cada uno de los 4 workers:
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
*Salida esperada:*  
Cada nodo muestra en su columna `LABELS` su etiqueta correspondiente: `role=frontend`, `role=backend1`, `role=backend2`, `role=mongodb`.

> 📸 **Captura requerida (Criterio 1):** Tomar captura de pantalla de la salida de `kubectl get nodes --show-labels`.

---

# 🗄️ PASO 6: CREAR LA RDS (`SQL SERVER EXPRESS` EN CONSOLA WEB AWS)

### 6.1 Crear la base de datos en la Consola Web de AWS
* **Dónde se hace:** En la **Consola de AWS** ➔ En el buscador escribe **RDS** y entra al servicio ➔ Menú **Databases** (Bases de datos) ➔ Haz clic en el botón naranja **"Create database"** (Crear base de datos).

Configura los campos exactamente así:
1. **Choose a database creation method:** Marca **Standard create** (Creación estándar).
2. **Engine options (Opciones de motor):**
   - Elige **Microsoft SQL Server**.
   - En **Edition (Edición):** Selecciona **SQL Server Express Edition** (es la versión gratuita/económica).
3. **Templates (Plantillas):** Selecciona **Free tier** o **Dev/Test**.
4. **Settings (Configuración):**
   - **DB instance identifier:** `visonsdb`
   - **Master username:** `admin`
   - **Master password:** Escribe tu contraseña (ej: `diego1416` o la que prefieras, y recuérdala).
   - **Confirm master password:** Vuelve a escribir tu contraseña.
5. **Instance configuration:**
   - **DB instance class:** Elige `Burstable classes` (incluye clases t) ➔ `db.t3.micro` o `db.t3.small`.
6. **Storage (Almacenamiento):**
   - **Storage type:** `gp3` o `gp2`, tamaño `20 GiB`.
   - **Storage autoscaling:** Puedes desactivarlo o dejarlo en 100.
7. **Connectivity (Conectividad):**
   - **Virtual Private Cloud (VPC):** Selecciona tu **Default VPC** (la misma donde están tus 5 EC2).
   - **Public access (Acceso público):** Marca **No** (las EC2 acceden internamente por la VPC).
   - **VPC security group (firewall):** Marca **"Choose existing"** (Elegir existentes):
     - Quita el grupo `default` de la lista.
     - Selecciona **únicamente `visons-rds-sg`**.
8. Haz clic abajo en el botón naranja **Create database**.

> ⏳ **Tiempo de espera:** La base de datos tardará entre 5 y 10 minutos en crearse.  
> Espera hasta que la columna **Status** pase de `Creating` a **`Available`**.  
> Haz clic sobre `visonsdb` y copia el valor de **Endpoint** que aparece en la sección *Connectivity & security* (ej: `visonsdb.cxxxxx.us-east-1.rds.amazonaws.com`).

---

### 6.2 Instalar herramienta sqlcmd y validar conectividad en Master
* **Máquina donde se ejecuta:** Terminal de **`visons-master`**

```bash
# 1. Instalar la herramienta oficial de Microsoft (go-sqlcmd) y netcat:
sudo apt-get update -qq && sudo apt-get install -y -qq bzip2 curl netcat-traditional
curl -sSL "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.2/sqlcmd-linux-amd64.tar.bz2" | sudo tar -xj -C /usr/local/bin
sudo chmod +x /usr/local/bin/sqlcmd

# 2. Probar conectividad al puerto 1433 de tu RDS (reemplaza con tu Endpoint real):
nc -zv <TU_ENDPOINT_RDS> 1433
```

✅ **Verificación del Paso 6:**  
*Salida esperada:*  
`Connection to visonsdb.xxxx.us-east-1.rds.amazonaws.com 1433 port [tcp/ms-sql-s] succeeded!`

---

# 📦 PASO 7: DESPLEGAR LOS PODS Y LLENAR LAS BASES DE DATOS
* **Máquina donde se ejecuta:** Terminal de **`visons-master`**

### 7.1 Clonar el Repositorio Directo
```bash
cd ~
rm -rf kubernetes
git clone https://github.com/diegoECV/kubernetes.git
cd kubernetes
```

---

### 7.2 Inyectar Variables de tu Entorno en los Manifiestos
* **Máquina donde se ejecuta:** Terminal de **`visons-master`**

> ⚠️ Reemplaza los 3 valores con tus datos reales:
> - `RDS_ENDPOINT`: El endpoint de tu RDS copiado en el Paso 6.
> - `RDS_PASSWORD`: La contraseña que le pusiste a la RDS (en comillas simples).
> - `ELASTIC_IP`: La **IP pública de tu instancia `visons-master`** (se ve en la consola EC2).

```bash
RDS_ENDPOINT="<TU_ENDPOINT_RDS>"
RDS_USER="admin"
RDS_PASSWORD='<TU_PASSWORD_RDS>'
ELASTIC_IP="<IP_PUBLICA_DEL_MASTER>"

# 1. Inyectar conexión en ConfigMaps:
sed -i "s|r2dbc:mssql://sqlserver-service:1433/Visons|r2dbc:mssql://$RDS_ENDPOINT:1433/Visons|g" k8s/02-configmaps.yaml
sed -i "s|SPRING_R2DBC_USERNAME: \"sa\"|SPRING_R2DBC_USERNAME: \"$RDS_USER\"|g" k8s/02-configmaps.yaml
sed -i "s|SQL_SERVER: \"sqlserver-service\"|SQL_SERVER: \"$RDS_ENDPOINT\"|g" k8s/02-configmaps.yaml
sed -i "s|SQL_USER: \"sa\"|SQL_USER: \"$RDS_USER\"|g" k8s/02-configmaps.yaml
sed -i "s|FRONTEND_URL:.*|FRONTEND_URL: \"http://$ELASTIC_IP:30080\"|g" k8s/02-configmaps.yaml

# 2. Inyectar contraseña en Secrets (seguro contra signos !):
sed -i "s|SPRING_R2DBC_PASSWORD:.*|SPRING_R2DBC_PASSWORD: \"$RDS_PASSWORD\"|g" k8s/01-secrets.yaml
sed -i "s|SQL_PASSWORD:.*|SQL_PASSWORD: \"$RDS_PASSWORD\"|g" k8s/01-secrets.yaml
```

---

### 7.3 Desplegar los Manifiestos de Kubernetes
> ⚠️ **REGLA ARQUITECTURAL:** Desplegamos MongoDB en el clúster. **NO** desplegamos `sqlserver.yaml` porque SQL Server corre en Amazon RDS.

```bash
# 1. Crear Namespace, Secretos y ConfigMaps
kubectl apply -f k8s/00-namespace.yaml
kubectl apply -f k8s/01-secrets.yaml
kubectl apply -f k8s/02-configmaps.yaml

# 2. Desplegar MongoDB
kubectl apply -f k8s/databases/mongodb.yaml

# 3. Desplegar Backend 1 Transaccional (Spring Boot)
kubectl apply -f k8s/backend-transaccional/

# 4. Desplegar Backend 2 Analítico (Python Flask)
kubectl apply -f k8s/backend-analitico/

# 5. Desplegar Frontend Web (React + Vite)
kubectl apply -f k8s/frontend-web/

# Esperar 25 segundos a que todos los contenedores inicien:
sleep 25
```

---

### 7.4 Inyectar la IP Pública y Corregir Frontend React
```bash
kubectl exec -n visons-prod deployment/frontend-web -- sh -c \
  "sed -i \"s|classList.add.*|classList.add('dark'); }|g\" /usr/share/nginx/html/index.html 2>/dev/null || true; sed -i 's|http://localhost:9090|http://$ELASTIC_IP:30090|g; s|http://localhost:5000|http://$ELASTIC_IP:30500|g; s|34.228.12.107|$ELASTIC_IP|g; s|54.234.91.155|$ELASTIC_IP|g; s|52.73.219.160|$ELASTIC_IP|g; s|\\.patch(\\([^)]*restore\\)|\\.put(\\1|g' /usr/share/nginx/html/assets/*.js"
```

---

### 7.5 Llenar las Bases de Datos (MongoDB y Amazon RDS SQL Server)
```bash
# Ejecutar el script maestro automatizado incluido en el repositorio:
bash scripts/seed-databases.sh
```

*(Si prefieres ejecutar el poblado manualmente paso a paso):*
```bash
# A. Poblar MongoDB (16 colecciones completas):
curl -sSL https://raw.githubusercontent.com/diegoECV/FN1/main/database-p/init/Visons_mongodb_completo.js | \
  kubectl exec -i -n visons-prod deployment/mongodb -- mongosh -u admin -p admin123 --authenticationDatabase admin Visons

# B. Poblar RDS SQL Server (11 tablas de negocio con 10 registros cada una):
curl -sSL https://raw.githubusercontent.com/diegoECV/FN1/main/database-p/init/Visons_sqlserver_completo.sql -o /tmp/Visons_sqlserver_completo.sql
sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -i /tmp/Visons_sqlserver_completo.sql
```

---

### 7.6 Probar Conectividad Interna entre Backend 1 y Backend 2 (`CRITERIO 2`)
```bash
# 1. Probar resolución DNS interna de Kubernetes:
kubectl run dns-test -n visons-prod --rm -i --restart=Never --image=busybox:1.36 -- nslookup backend-analitico-service

# 2. Llamada HTTP pod-a-pod directa por DNS interno:
kubectl exec -n visons-prod deployment/backend-analitico -- python3 -c \
  "import urllib.request; resp = urllib.request.urlopen('http://backend-transaccional-service:9090/actuator/health'); print('Respuesta Backend1:', resp.read().decode())"
```
*Salida esperada:*  
`Respuesta Backend1: {"status":"UP"}`

---

✅ **Verificación del Paso 7 (EVIDENCIA DE EVALUACIÓN - CRITERIO 1, 2 Y 3):**
* **Máquina donde se ejecuta:** Terminal de **`visons-master`**

```bash
# 1. Verificar que cada pod corre en su worker correspondiente (CRITERIO 1):
kubectl get pods -n visons-prod -o wide

# 2. Verificar las 11 tablas pobladas en RDS SQL Server (CRITERIO 3):
sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -d Visons -Q \
  "SELECT t.name AS Tabla, p.rows AS Total_Filas FROM sys.tables t JOIN sys.partitions p ON t.object_id = p.object_id WHERE p.index_id IN (0,1) AND t.name != 'schema_change' ORDER BY t.name;"
```

> 📸 **Capturas requeridas:**
> 1. Salida de `kubectl get pods -n visons-prod -o wide` mostrando los 4 pods en estado `Running` en sus 4 workers asignados.
> 2. Salida de la llamada pod-a-pod mostrando `{"status":"UP"}`.
> 3. Tabla de SQL Server mostrando las 11 entidades y sus 10 registros cada una.

---

# 🎯 PASO 8: PROBAR LOS ENDPOINTS (POSTMAN / SWAGGER / WEB) Y TOMAR CAPTURAS (`CRITERIO 4`)

### 8.1 Prueba de Login JWT (Spring Boot Backend 1)
* **Dónde se prueba:** En **Postman** o directamente en la terminal de `visons-master`:
  * **Método:** `POST`
  * **URL:** `http://<IP_PUBLICA_MASTER>:30090/api/v1/auth/login`
  * **Headers:** `Content-Type: application/json`
  * **Body (raw JSON):**
    ```json
    {
      "username": "admin@visons.com",
      "password": "password123"
    }
    ```
* **En terminal del Master:**
```bash
curl -s -X POST http://localhost:30090/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin@visons.com","password":"password123"}'
echo ""
```
> 📸 **Captura requerida (Criterio 4):** Token JWT devuelto exitosamente en Postman o terminal.

---

### 8.2 Prueba de KPIs Analíticos (Python Flask Backend 2)
* **Dónde se prueba:** En **Postman** o navegador:
  * **Método:** `GET`
  * **URL:** `http://<IP_PUBLICA_MASTER>:30500/api/v1/analytics/dashboard/kpis`
* **En terminal del Master:**
```bash
curl -s http://localhost:30500/api/v1/analytics/dashboard/kpis | cut -c 1-135
echo ""
```
> 📸 **Captura requerida (Criterio 4):** JSON con métricas reales (`total_inspecciones: 10`, `facturacion_total_usd: 25860.0`).

---

### 8.3 Prueba de Swagger UI (Documentación OpenAPI)
* **Dónde se prueba:** En tu navegador web:
  * **URL:** `http://<IP_PUBLICA_MASTER>:30090/swagger-ui.html`
> 📸 **Captura requerida (Criterio 4):** Página interactiva de Swagger UI de Spring Boot cargada.

---

### 8.4 Prueba del Frontend Web React
* **Dónde se prueba:** En tu navegador web:
  * **URL:** `http://<IP_PUBLICA_MASTER>:30080`
  * **Credenciales de acceso:**  
    * **Email:** `admin@visons.com`  
    * **Password:** `password123`
> 📸 **Captura requerida (Criterio 4):** Pantalla del Dashboard de Visons con las tablas y métricas visuales cargadas sin errores en consola.

---

## 🛠️ APÉNDICE A: TABLA DE TROUBLESHOOTING (LOS 9 PROBLEMAS PREVENIDOS)

| # | Problema Anterior | Causa Técnica | Prevención en este Manual |
|---|---|---|---|
| **1** | Submódulo vacío al clonar | Clonar monorepo `FN1` dejaba submódulos vacíos | Clonar directo `https://github.com/diegoECV/kubernetes.git` (Paso 7.1). |
| **2** | Error `-bash: !: event not found` | Bash interpreta `!` como historial | Uso de comillas simples `'...'` y comodines regex en `sed` (Paso 7.2). |
| **3** | MongoDB en `Pending` | Falta de StorageClass para PVC dinámico | Uso de `hostPath: /data/mongodb` con permisos 777 en worker dedicado (Paso 4.4). |
| **4** | Spring Boot en `CrashLoop` | Sonda a `/actuator/info` daba 401 | Sonda configurada con `tcpSocket: port: 9090` + RAM pooled (Paso 7.3). |
| **5** | Timeout al puerto 10250 | Puerto 10250 bloqueado entre instancias | Regla 10250 y Todo el Tráfico entre SGs desde el inicio (Paso 1.2). |
| **6** | Bases de datos vacías | RDS y Mongo inician vírgenes | Script de poblado `scripts/seed-databases.sh` (Paso 7.5). |
| **7** | Error FK en SQL Server (`Msg 547`) | `DBCC RESEED, 0` generaba IDs desde 0 | `SET IDENTITY_INSERT ON` + `NOCHECK CONSTRAINT all` (Paso 7.5). |
| **8** | "La conexión ha caducado" | Puerto NodePort 30080 cerrado en AWS | Regla `TCP 30080` a `0.0.0.0/0` en SGs desde el inicio (Paso 1.2). |
| **9** | Master no tiene `sqlcmd` | Ubuntu EC2 no incluye cliente de SQL | Instalación de `go-sqlcmd` en `/usr/local/bin/sqlcmd` (Paso 6.2). |

---

## 📋 APÉNDICE B: CHECKLIST DE ENTREGA PARA EVALUACIÓN (20/20)

| Criterio Evaluado | Comando de Demostración en Vivo | Evidencia / Captura Requerida |
|---|---|---|
| **Criterio 1: Nodos Aislados** | `kubectl get nodes --show-labels` y `kubectl get pods -n visons-prod -o wide` | Captura con los 4 pods en sus 4 worker nodes específicos. |
| **Criterio 2: Conectividad Interna** | `kubectl exec -n visons-prod deployment/backend-analitico -- python3 -c "import urllib.request; print(urllib.request.urlopen('http://backend-transaccional-service:9090/actuator/health').read().decode())"` | Captura mostrando respuesta `{"status":"UP"}` usando DNS interno. |
| **Criterio 3: Persistencia Políglota** | `sqlcmd -S $RDS_ENDPOINT ... -Q "SELECT count(*) FROM ORDERS"` y conteo en Mongo | Captura de las 11 tablas con 10 filas en RDS y 16 colecciones en Mongo. |
| **Criterio 4: Endpoints Expuestos** | `curl -X POST .../login` y `http://<IP>:30080` en navegador | Captura del Token JWT en Postman y Dashboard Web funcional. |

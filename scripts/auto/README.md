# 🚀 Visons — Despliegue automático en Kubernetes (5 EC2 + RDS + MongoDB)

Reemplaza el copiar/pegar del manual por scripts que **detectan solos** la IP pública, la IP privada,
el token de `kubeadm join`, el endpoint de la RDS y configuran los manifiestos.
**Lo único que escribes es la contraseña de la RDS, una vez, en `config.env`.**

```
 TÚ                         master (EC2)                         workers (EC2 ×4)
 ───                        ────────────                         ────────────────
 clics: SGs, EC2, RDS  ──►  node.sh master                       node.sh <rol> <IP_PRIVADA_MASTER>
 (o provision-aws.sh)        ├ init + Flannel                     ├ prepara el nodo
                             ├ publica el join (solo VPC)  ◄──────┤ lee el join SOLO (sin copiar token)
                             ├ etiqueta role=… cuando se unen     └ se etiqueta role=<rol>
 config.env (1 vez)  ──►  deploy.sh
                             ├ detecta IP pública + endpoint RDS
                             ├ comprueba SG → RDS:1433
                             ├ MongoDB → siembra RDS y Mongo → backends → frontend
                             └ verify.sh (pruebas reales + las 4 capturas)
```

## Archivos
| Archivo | Para qué sirve |
|---|---|
| `config.env.example` | Variables. Cópialo a `config.env` y pon `RDS_PASSWORD` (no se sube a git). |
| `node.sh` | Prepara cada nodo y lo une al clúster (Pasos 2.2, 3, 4 y 5 del manual). Autocontenido. |
| `deploy.sh` | Despliega todo en el master (Pasos 6.2 y 7). **Re-ejecutable** para actualizar. |
| `verify.sh` | Pruebas reales + evidencias (Pasos 7.6 y 8). Lo llama `deploy.sh`. |
| `diagnose.sh` | Busca la causa exacta de errores 500, CORS y "restaurar" (solo lee). |
| `render.py` | Inyecta IPs/claves en los manifiestos **sin editar tus archivos** (lo usa `deploy.sh`). |
| `lib.sh` | Funciones comunes (IMDS, config, reintentos). |
| `provision-aws.sh` | *Opcional*: crea SGs + EC2 + RDS con AWS CLI en vez de clics. |

## Paso 0 — una sola vez, en tu PC
1. Copia esta carpeta a tu repo como `scripts/auto/`, y haz commit + push a la rama `develop`.
2. Agrega a `.gitignore` del repo:  `scripts/auto/config.env`  (tu clave no debe subirse; el repo es público).

## Opción A — Consola web (como tu manual) + scripts

### A1. Security Groups (crea los 3 vacíos y luego las reglas)
| Grupo | Entrada (Inbound) |
|---|---|
| `visons-master-sg` | TCP 22 ← 0.0.0.0/0 · TCP 30080, 30090, 30500 ← 0.0.0.0/0 · **All traffic ← `visons-workers-sg`** |
| `visons-workers-sg` | TCP 22 ← 0.0.0.0/0 · **All traffic ← `visons-master-sg`** · **All traffic ← `visons-workers-sg` (sí mismo)** · TCP 30080, 30090, 30500 ← 0.0.0.0/0 |
| `visons-rds-sg` | MS SQL 1433 ← `visons-master-sg` · MS SQL 1433 ← `visons-workers-sg` |

Cambios respecto a tu manual: ya no se abre **6443 a todo Internet** (solo lo necesitan los workers, y ya entra por
"All traffic" del grupo); y en los workers solo se abren los 3 NodePorts que usas, no 30000-32767.
"All traffic" entre los grupos cubre kubelet 10250, Flannel (UDP 8472), DNS, MongoDB 27017 y el join (8088).

### A2. Las 5 EC2 (igual que tu manual: Ubuntu 22.04, t3.medium, 20 GiB gp3, IP pública habilitada)
Nombres exactos: `visons-master`, `visons-worker-frontend`, `visons-worker-backend1`, `visons-worker-backend2`, `visons-worker-mongodb`.

### A3. Master (EC2 Instance Connect)
```bash
curl -fsSL https://raw.githubusercontent.com/diegoECV/kubernetes/develop/scripts/auto/node.sh | sudo bash -s -- master
```
Al terminar de instalar imprime **4 líneas ya listas** (con la IP privada del master puesta). Déjalo abierto.

### A4. Workers (una línea en cada uno, las que imprimió el master)
```bash
curl -fsSL https://raw.githubusercontent.com/diegoECV/kubernetes/develop/scripts/auto/node.sh | sudo bash -s -- frontend 172.31.x.x
```
(igual con `backend1`, `backend2`, `mongodb`). El master etiqueta y avisa cuando los 5 están `Ready`.

### A5. RDS (consola) y despliegue
Crea la RDS como en tu manual (identificador `visonsdb`, usuario `admin`, **la clave que pusiste en `config.env`**, `visons-rds-sg`).
Cuando esté `Available`, en el master:
```bash
cd ~/kubernetes/scripts/auto
cp -n config.env.example config.env && nano config.env     # solo RDS_PASSWORD
bash deploy.sh
```
Si la EC2 no puede consultar la RDS por `aws cli`, te pide el endpoint **una vez** y lo recuerda.

## Opción B — Todo por CLI (CloudShell o tu PC con `aws configure`)
```bash
cp config.env.example config.env && nano config.env      # RDS_PASSWORD, KEY_NAME…
bash provision-aws.sh      # SGs + 5 EC2 (se instalan solas) + RDS
# luego, en el master:  cd ~/kubernetes/scripts/auto && bash deploy.sh
```

## Actualizar / reparar (lo que antes era "quería actualizarlo pero nada")
| Situación | Qué hacer |
|---|---|
| El lab se reinició y **cambió la IP pública** | En el master: `bash deploy.sh` (reinyecta la IP y reinicia solo lo que cambió) |
| Cambiaste una clave o variable | Edita `config.env` → `bash deploy.sh` |
| Quieres ver qué falla | `bash verify.sh` (te dice qué capa y qué comando mirar) |
| Recreaste la RDS (otro endpoint) | `rm ~/.visons/state.env` → `bash deploy.sh` |

## Fallos del manual original que estos scripts corrigen
| # | Fallo | Efecto | Corrección |
|---|---|---|---|
| 1 | En 7.2 las variables no llevan `export`, y `seed-databases.sh` trae un endpoint y clave **fijos** de otra RDS | El poblado iba a la RDS equivocada o fallaba, sin avisar | `deploy.sh` siembra con las variables reales |
| 2 | Se despliegan los backends **antes** de sembrar | Pods `Running` con BD vacía → login falla | Se siembra **antes** de arrancar los backends |
| 3 | Sondas `tcpSocket` en Spring Boot | `Running` aunque no conecte a la RDS/Mongo | `verify.sh` prueba login, KPIs, health y logs reales |
| 4 | 7.4 hace `kubectl exec sed` en el frontend, y el Deployment trae un `postStart` con la IP vieja `52.73.219.160` | Al reiniciarse el pod, el frontend volvía a la IP vieja | La IP actual se inyecta en el `postStart` del Deployment (persistente) |
| 5 | `sed` con la clave dentro | Claves con `\|`, `&` o `\` rompían los manifiestos | `render.py` (JSON), probado con `P@ss\|w&rd!$"x` |
| 6 | `mongodb.yaml` crea un PVC que nadie usa (MongoDB usa `hostPath`) | PVC `Pending` eterno que parece error | No se aplica ese PVC |
| 7 | `sqlcmd` sin `-C` ni `-b` | Posible rechazo TLS con RDS y errores SQL silenciosos | `-C` y `-b`, con log del seed |
| 8 | `kubeadm init` sin `--apiserver-advertise-address` y Flannel `latest` | Dependía de qué IP elegía kubeadm; versión cambiante | IP privada explícita; Flannel fijado a v0.25.5 (con respaldo a latest) |
| 9 | Token/hash copiados a mano a 4 máquinas | Token vencido o mal pegado | El master los publica solo dentro de la VPC y los workers los leen |

## Nota sobre `deploy-visons.sh` (modo 2) del repo
No lo uses con este flujo: etiqueta el nodo Mongo como `role=database-mongo` (el manifiesto pide `role=mongodb`) y pone *taints*
que los Deployments no toleran → pods `Pending`. Además busca los SQL/JS en `database-p/`, que no existe en este repo.

## Qué NO pude verificar
Probé con un simulacro (kubectl/sqlcmd/metadata falsos) el orden, los valores inyectados y los errores, y pasé `shellcheck`.
No pude ejecutarlo contra AWS real ni descargar tus imágenes de Docker Hub. Si algo falla en tu cuenta (sobre todo `provision-aws.sh`
con los permisos de AWS Academy), pega la salida de `bash verify.sh` y lo ajustamos.

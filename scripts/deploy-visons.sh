#!/usr/bin/env bash
# =============================================================================
#   VISONS S.A.C. — SCRIPT MAESTRO UNIFICADO
#   Soporta DOS modos de despliegue según el rubric:
#
#   MODO 1: "Taller de Cloud Computing"
#     → 2 BDs AWS diferentes (RDS SQL Server + EC2 MongoDB)
#     → 2 backends + 1 frontend usando servicios AWS distintos
#
#   MODO 2: "Orquestadores y Automatización"
#     → Kubernetes sobre EC2 con aislamiento de nodos dedicados
#     → Backend 1 (Spring Boot) + Backend 2 (Flask) con conectividad interna
#     → Persistencia políglota: SQL Server en RDS + MongoDB en EC2/Atlas
# =============================================================================
#
#   USO:
#     bash scripts/deploy-visons.sh        ← te pregunta qué modo
#     bash scripts/deploy-visons.sh 1      ← Modo 1: Taller Cloud
#     bash scripts/deploy-visons.sh 2      ← Modo 2: Orquestadores K8s
#
#   EJECUTAR DESDE: kubernetes/
# =============================================================================

set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║              🏷️  ZONA DE VARIABLES — CAMBIA AQUÍ TUS IPs               ║
# ║         (Estas son las únicas líneas que debes modificar)               ║
# ╠══════════════════════════════════════════════════════════════════════════╣
# ║                                                                          ║
# ║  INSTRUCCIONES:                                                          ║
# ║  1. Pon la IP pública de tu EC2 Master en MASTER_IP                     ║
# ║  2. Pon el endpoint de tu RDS SQL Server en RDS_ENDPOINT                ║
# ║  3. Pon la IP de tu EC2 MongoDB (o Atlas URI) en MONGO_HOST             ║
# ║  4. Guarda y ejecuta: bash scripts/deploy-visons.sh                     ║
# ║                                                                          ║
# ╠══════════════════════════════════════════════════════════════════════════╣

# ── 🌐 IPs del Clúster ────────────────────────────────────────────────────
MASTER_IP="54.0.0.0"                  # ← IP pública del EC2 Master (EIP AWS)
WORKER_FRONTEND_IP="10.0.1.10"        # ← IP privada del EC2 Worker Frontend
WORKER_BACKEND1_IP="10.0.1.11"        # ← IP privada del EC2 Worker Backend-T
WORKER_BACKEND2_IP="10.0.1.12"        # ← IP privada del EC2 Worker Backend-A
WORKER_MONGO_IP="10.0.1.13"           # ← IP privada del EC2 Worker MongoDB

# ── 🛢  Base de Datos SQL Server (Amazon RDS) ─────────────────────────────
RDS_ENDPOINT="visons-db.xxxx.us-east-1.rds.amazonaws.com"  # ← Endpoint de tu RDS
RDS_PORT="1433"
RDS_DATABASE="Visons"
RDS_USER="admin"                       # ← Usuario RDS (no 'sa', es 'admin' en RDS)
RDS_PASSWORD="Password123!"            # ← Contraseña RDS

# ── 🍃 Base de Datos MongoDB (EC2 o Atlas) ────────────────────────────────
MONGO_HOST="mongodb-service"           # ← Si es in-cluster: "mongodb-service"
                                       # ← Si es EC2 externo: IP privada del EC2 Mongo
                                       # ← Si es Atlas: "cluster0.xxxxx.mongodb.net"
MONGO_PORT="27017"
MONGO_DB="Visons"
MONGO_USER="admin"
MONGO_PASS="admin123"                  # ← Contraseña MongoDB

# ── 🔑 Credenciales Generales ────────────────────────────────────────────
JWT_SECRET="EsteEsUnSecretoMuyLargoParaJWT2026VisonsSACAutenticacionSegura"
MSSQL_SA_PASSWORD="Password123!"      # ← Para SQL Server in-cluster (Modo 1)

# ── 🐳 Imágenes Docker Hub ───────────────────────────────────────────────
DOCKER_USER="diego5621"               # ← Tu usuario de Docker Hub
IMG_BACKEND_T="${DOCKER_USER}/backend-transaccional:latest"
IMG_BACKEND_A="${DOCKER_USER}/backend-analitico:latest"
IMG_FRONTEND="${DOCKER_USER}/frontend-web:latest"

# ── 📦 Namespace ──────────────────────────────────────────────────────────
NS="visons-prod"
K8S_DIR="k8s"

# ╚══════════════════════════════════════════════════════════════════════════╝

# ── Colores ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_step() { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"
             echo -e "${CYAN}  🎯 $1${NC}"
             echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"; }
log_ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
log_info() { echo -e "${BLUE}  ℹ  $1${NC}"; }
log_warn() { echo -e "${YELLOW}  ⚠  $1${NC}"; }
log_err()  { echo -e "${RED}  ❌ $1${NC}"; exit 1; }

# ── Selección de modo ─────────────────────────────────────────────────────
select_mode() {
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║       VISONS S.A.C. — SELECTOR DE DESPLIEGUE        ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${NC}\n"
    echo -e "  ${BOLD}[1]${NC} Taller de Cloud Computing"
    echo -e "      → 2 BDs AWS (RDS SQL Server + EC2 MongoDB)"
    echo -e "      → Deployments directos en EC2 (sin K8s obligatorio)"
    echo ""
    echo -e "  ${BOLD}[2]${NC} Orquestadores y Automatización de Software"
    echo -e "      → Kubernetes sobre EC2 con nodos aislados"
    echo -e "      → Frontend, Backend-T y Backend-A en nodos dedicados"
    echo -e "      → SQL Server en RDS + MongoDB en EC2/in-cluster"
    echo ""
    read -rp "  Elige modo [1/2]: " MODE
}

MODE="${1:-}"
[ -z "$MODE" ] && select_mode

# ═════════════════════════════════════════════════════════════════════════════
# ── FUNCIONES COMPARTIDAS (usadas en ambos modos) ─────────────────────────
# ═════════════════════════════════════════════════════════════════════════════

check_kubectl() {
    command -v kubectl &>/dev/null || log_err "kubectl no encontrado."
    kubectl cluster-info &>/dev/null || log_err "No se puede contactar el clúster."
    log_ok "Clúster conectado: $(kubectl config current-context)"
}

# Genera ConfigMap con las IPs/endpoints reales (sin tocar archivos fuente)
render_configmap() {
    local mongo_uri="mongodb://${MONGO_USER}:${MONGO_PASS}@${MONGO_HOST}:${MONGO_PORT}/${MONGO_DB}?authSource=admin"
    local r2dbc_url="r2dbc:sqlserver://${RDS_ENDPOINT}:${RDS_PORT};database=${RDS_DATABASE};encrypt=true;trustServerCertificate=true"

    cat << CONFIGMAP
apiVersion: v1
kind: ConfigMap
metadata:
  name: visons-config
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: "visons-platform"
data:
  # Backend Transaccional (Spring Boot)
  SERVER_PORT: "9090"
  SPRING_R2DBC_URL: "${r2dbc_url}"
  SPRING_R2DBC_USERNAME: "${RDS_USER}"
  FRONTEND_URL: "http://${MASTER_IP}:30080"
  JWT_EXPIRATION_MS: "36000000"
  MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE: "health,info,prometheus,metrics"
  MANAGEMENT_ENDPOINT_HEALTH_SHOW_DETAILS: "always"
  MANAGEMENT_PROMETHEUS_METRICS_EXPORT_ENABLED: "true"
  # Backend Analítico (Flask)
  FLASK_PORT: "5000"
  FLASK_DEBUG: "False"
  SQL_SERVER: "${RDS_ENDPOINT}"
  SQL_PORT: "${RDS_PORT}"
  SQL_DATABASE: "${RDS_DATABASE}"
  SQL_USER: "${RDS_USER}"
  MONGO_DB_NAME: "${MONGO_DB}"
CONFIGMAP
}

render_secrets() {
    local mongo_uri="mongodb://${MONGO_USER}:${MONGO_PASS}@${MONGO_HOST}:${MONGO_PORT}/${MONGO_DB}?authSource=admin"
    local mongo_uri_direct="${mongo_uri}&directConnection=true"

    cat << SECRETS
apiVersion: v1
kind: Secret
metadata:
  name: visons-secrets
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: "visons-platform"
type: Opaque
stringData:
  SPRING_R2DBC_PASSWORD: "${RDS_PASSWORD}"
  SPRING_DATA_MONGODB_URI: "${mongo_uri}"
  JWT_SECRET: "${JWT_SECRET}"
  GOOGLE_CLIENT_ID: "visons-google-oauth-client-id.apps.googleusercontent.com"
  GOOGLE_CLIENT_SECRET: "GOCSPX-dummy-secret-visons-sac-2026"
  SQL_PASSWORD: "${RDS_PASSWORD}"
  MONGO_URI: "${mongo_uri_direct}"
  MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD}"
  MONGO_INITDB_ROOT_USERNAME: "${MONGO_USER}"
  MONGO_INITDB_ROOT_PASSWORD: "${MONGO_PASS}"
SECRETS
}

apply_base_config() {
    log_step "Aplicando Namespace, Secrets y ConfigMaps"
    kubectl apply -f "${K8S_DIR}/00-namespace.yaml"

    # Secrets con valores reales
    render_secrets | kubectl apply -f -
    log_ok "Secrets aplicados (RDS: ${RDS_ENDPOINT} / Mongo: ${MONGO_HOST})"

    # ConfigMap con valores reales
    render_configmap | kubectl apply -f -
    log_ok "ConfigMap aplicado (FRONTEND_URL: http://${MASTER_IP}:30080)"
}

wait_for() {
    local name=$1 timeout=${2:-120}
    log_info "Esperando deployment/$name (máx ${timeout}s)..."
    kubectl rollout status deployment/"$name" -n "$NS" --timeout="${timeout}s" \
        && log_ok "$name → READY" \
        || log_warn "$name: aún iniciando en background"
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCIÓN: seed_databases
# Carga las tablas + datos semilla en SQL Server y MongoDB.
# Es IDEMPOTENTE — puede ejecutarse múltiples veces sin duplicar registros.
# Los scripts originales ya tienen lógica de limpieza previa.
# ─────────────────────────────────────────────────────────────────────────────
seed_databases() {
    log_step "🌱 Inicializando datos en SQL Server y MongoDB"

    # Detectar ruta absoluta de los scripts de inicialización
    local CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    local ROOT_DIR=""
    if [ -d "${CURRENT_DIR}/../../database-p" ]; then
        ROOT_DIR="$(cd "${CURRENT_DIR}/../.." && pwd)"
    elif [ -d "${CURRENT_DIR}/../database-p" ]; then
        ROOT_DIR="$(cd "${CURRENT_DIR}/.." && pwd)"
    else
        ROOT_DIR="$(pwd)"
    fi
    SQL_SCRIPT="${ROOT_DIR}/database-p/init/Visons_sqlserver_completo.sql"
    MONGO_SCRIPT="${ROOT_DIR}/database-p/init/Visons_mongodb_completo.js"

    if [ ! -f "$SQL_SCRIPT" ]; then
        log_warn "No se encontró: $SQL_SCRIPT — seed SQL omitido"
    fi
    if [ ! -f "$MONGO_SCRIPT" ]; then
        log_warn "No se encontró: $MONGO_SCRIPT — seed MongoDB omitido"
    fi

    # ── SQL Server ─────────────────────────────────────────────────────────
    seed_sqlserver() {
        local sql_file=$1
        log_info "Buscando pod de SQL Server..."

        # Intentar con pod in-cluster primero
        local SQL_POD
        SQL_POD=$(kubectl get pods -n "$NS" -l app=sqlserver \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$SQL_POD" ]; then
            log_info "Pod SQL Server in-cluster: $SQL_POD"
            log_info "Copiando script SQL al pod..."
            kubectl cp "$sql_file" "${NS}/${SQL_POD}:/tmp/Visons_sqlserver_completo.sql"
            log_info "Ejecutando script SQL (puede tardar 15-30s)..."
            kubectl exec "$SQL_POD" -n "$NS" -- /opt/mssql-tools18/bin/sqlcmd \
                -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" \
                -i /tmp/Visons_sqlserver_completo.sql \
                -C -l 30 2>/dev/null \
                && log_ok "SQL Server: tablas y datos semilla cargados ✅" \
                || { 
                    # Intento alternativo con sqlcmd sin -C (versiones antiguas)
                    kubectl exec "$SQL_POD" -n "$NS" -- /opt/mssql-tools/bin/sqlcmd \
                        -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" \
                        -i /tmp/Visons_sqlserver_completo.sql -l 30 2>/dev/null \
                        && log_ok "SQL Server: datos cargados (sqlcmd alternativo) ✅" \
                        || log_warn "SQL Server: seed falló — ejecuta manualmente:" ; \
                        log_warn "  kubectl cp $sql_file ${NS}/${SQL_POD}:/tmp/init.sql" ; \
                        log_warn "  kubectl exec -n ${NS} ${SQL_POD} -- sqlcmd -S localhost -U sa -P '${MSSQL_SA_PASSWORD}' -i /tmp/init.sql -C"
                }
        elif [[ "$RDS_ENDPOINT" == *"rds.amazonaws.com"* ]]; then
            # SQL Server externo en RDS — usar sqlcmd local si está disponible
            if command -v sqlcmd &>/dev/null; then
                log_info "SQL Server en RDS — ejecutando script con sqlcmd local..."
                sqlcmd -S "${RDS_ENDPOINT},${RDS_PORT}" \
                    -U "${RDS_USER}" -P "${RDS_PASSWORD}" \
                    -i "$sql_file" -C -l 30 \
                    && log_ok "RDS SQL Server: datos cargados ✅" \
                    || log_warn "RDS seed falló — ejecuta el script manualmente desde tu PC"
            else
                log_warn "sqlcmd no instalado localmente. Para cargar datos en RDS:"
                log_warn "  Instala: https://learn.microsoft.com/sql/tools/sqlcmd-utility"
                log_warn "  Luego:   sqlcmd -S ${RDS_ENDPOINT} -U ${RDS_USER} -P '${RDS_PASSWORD}' -i $sql_file -C"
            fi
        else
            log_warn "No se encontró pod SQL Server activo — seed omitido"
        fi
    }

    # ── MongoDB ────────────────────────────────────────────────────────────
    seed_mongodb() {
        local js_file=$1
        log_info "Buscando pod de MongoDB..."

        local MONGO_POD
        MONGO_POD=$(kubectl get pods -n "$NS" -l app=mongodb \
            --field-selector=status.phase=Running \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$MONGO_POD" ]; then
            log_info "Pod MongoDB in-cluster: $MONGO_POD"
            log_info "Copiando script JS al pod..."
            kubectl cp "$js_file" "${NS}/${MONGO_POD}:/tmp/Visons_mongodb_completo.js"
            log_info "Ejecutando script MongoDB (puede tardar 10-20s)..."
            kubectl exec "$MONGO_POD" -n "$NS" -- mongosh \
                --host localhost \
                --username "${MONGO_USER}" \
                --password "${MONGO_PASS}" \
                --authenticationDatabase admin \
                --quiet \
                /tmp/Visons_mongodb_completo.js 2>/dev/null \
                && log_ok "MongoDB: colecciones y datos semilla cargados ✅" \
                || { 
                    # Intento alternativo con mongo (versiones antiguas)
                    kubectl exec "$MONGO_POD" -n "$NS" -- mongo \
                        --host localhost \
                        -u "${MONGO_USER}" -p "${MONGO_PASS}" \
                        --authenticationDatabase admin \
                        /tmp/Visons_mongodb_completo.js 2>/dev/null \
                        && log_ok "MongoDB: datos cargados (mongo cli) ✅" \
                        || log_warn "MongoDB seed falló — ejecuta manualmente:" ; \
                        log_warn "  kubectl cp $js_file ${NS}/${MONGO_POD}:/tmp/init.js" ; \
                        log_warn "  kubectl exec -n ${NS} ${MONGO_POD} -- mongosh -u ${MONGO_USER} -p '${MONGO_PASS}' --authenticationDatabase admin /tmp/init.js"
                }
        else
            log_warn "No se encontró pod MongoDB activo — seed omitido"
            log_warn "Para cargarlo manualmente después:"
            log_warn "  kubectl cp $js_file ${NS}/<nombre-pod-mongodb>:/tmp/init.js"
            log_warn "  kubectl exec -n ${NS} <nombre-pod-mongodb> -- mongosh -u ${MONGO_USER} -p '${MONGO_PASS}' --authenticationDatabase admin /tmp/init.js"
        fi
    }

    [ -f "$SQL_SCRIPT" ]   && seed_sqlserver "$SQL_SCRIPT"
    [ -f "$MONGO_SCRIPT" ] && seed_mongodb   "$MONGO_SCRIPT"

    log_ok "Inicialización de bases de datos completada"
}

print_summary() {
    echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${GREEN}  🚀 DESPLIEGUE COMPLETADO — MODO $1${NC}"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
    echo -e "\n${BOLD}📦 Pods en $NS:${NC}"
    kubectl get pods -n "$NS" -o wide
    echo -e "\n${BOLD}🔌 Servicios:${NC}"
    kubectl get svc -n "$NS"
    echo -e "\n${BOLD}🌐 URLs (IP: ${MASTER_IP}):${NC}"
    echo -e "  Frontend:          ${GREEN}http://${MASTER_IP}:30080${NC}"
    echo -e "  Backend Spring:    ${GREEN}http://${MASTER_IP}:30090/api/v1${NC}"
    echo -e "  Backend Flask:     ${GREEN}http://${MASTER_IP}:30500/api/v1/analytics${NC}"
    echo -e "  Grafana:           ${GREEN}http://${MASTER_IP}:30300${NC}"
    echo -e "\n${BOLD}🛢  Bases de Datos conectadas:${NC}"
    echo -e "  SQL Server RDS:  ${CYAN}${RDS_ENDPOINT}:${RDS_PORT}${NC}"
    echo -e "  MongoDB:         ${CYAN}${MONGO_HOST}:${MONGO_PORT}${NC}"
    echo -e "\n${BOLD}🔍 Diagnóstico:${NC}"
    echo    "  kubectl get pods -n $NS -o wide"
    echo    "  kubectl logs -l app=backend-transaccional -n $NS --tail=50"
    echo    "  kubectl logs -l app=backend-analitico -n $NS --tail=50"
    echo -e "${CYAN}══════════════════════════════════════════════════════${NC}\n"
}

# ═════════════════════════════════════════════════════════════════════════════
# ── MODO 1: Taller de Cloud Computing ─────────────────────────────────────
# ═════════════════════════════════════════════════════════════════════════════
mode_1_cloud_taller() {
    log_step "MODO 1: Taller de Cloud Computing"
    log_info "2 BDs AWS (RDS SQL Server + EC2 MongoDB) + 2 backends + 1 frontend"

    check_kubectl

    # Paso 1 — Config base
    apply_base_config

    # Paso 2 — MongoDB in-cluster (EC2 worker dedicado)
    #   Solo si MONGO_HOST es el service interno, desplegamos el pod
    if [ "$MONGO_HOST" = "mongodb-service" ]; then
        log_step "Desplegando MongoDB in-cluster"
        kubectl apply -f "${K8S_DIR}/databases/mongodb.yaml"
        log_info "Esperando MongoDB..."
        kubectl rollout status deployment/mongodb -n "$NS" --timeout=180s \
            && log_ok "MongoDB READY" || log_warn "MongoDB tardando..."
    else
        log_info "MongoDB externo detectado (${MONGO_HOST}) — omitiendo deploy in-cluster"
    fi

    # Paso 3 — SQL Server solo si es in-cluster (RDS externo no necesita pod)
    if [[ "$RDS_ENDPOINT" == *"rds.amazonaws.com"* ]]; then
        log_info "SQL Server en RDS (${RDS_ENDPOINT}) — no se despliega pod in-cluster ✓"
    else
        log_step "Desplegando SQL Server in-cluster"
        kubectl apply -f "${K8S_DIR}/databases/sqlserver.yaml"
        kubectl rollout status deployment/sqlserver -n "$NS" --timeout=240s \
            && log_ok "SQL Server READY" || log_warn "SQL Server tardando..."
    fi

    # Paso 4 — Microservicios
    log_step "Desplegando Microservicios"
    kubectl apply -f "${K8S_DIR}/backend-transaccional/deployment.yaml"
    kubectl apply -f "${K8S_DIR}/backend-transaccional/service.yaml"
    kubectl apply -f "${K8S_DIR}/backend-transaccional/hpa.yaml" 2>/dev/null || true

    kubectl apply -f "${K8S_DIR}/backend-analitico/deployment.yaml"
    kubectl apply -f "${K8S_DIR}/backend-analitico/service.yaml"
    kubectl apply -f "${K8S_DIR}/backend-analitico/hpa.yaml" 2>/dev/null || true

    kubectl apply -f "${K8S_DIR}/frontend-web/deployment.yaml"
    kubectl apply -f "${K8S_DIR}/frontend-web/service.yaml"
    log_ok "Microservicios aplicados"

    # Paso 5 — Esperar readiness
    wait_for "backend-transaccional" 180
    wait_for "backend-analitico" 120
    wait_for "frontend-web" 90

    # Paso 6 — Cargar tablas y datos semilla
    seed_databases

    print_summary "1 — Taller Cloud Computing"
}

# ═════════════════════════════════════════════════════════════════════════════
# ── MODO 2: Orquestadores y Automatización ─────────────────────────────────
# ═════════════════════════════════════════════════════════════════════════════
mode_2_orquestadores() {
    log_step "MODO 2: Orquestadores y Automatización de Software"
    log_info "K8s con nodos aislados + RDS SQL Server + MongoDB EC2/in-cluster"

    check_kubectl

    # Paso 1 — Aislamiento de nodos (Labels + Taints)
    log_step "Aislando nodos del clúster (Labels + Taints)"

    WORKERS=($(kubectl get nodes --no-headers | grep -vE 'control-plane|master' | awk '{print $1}'))
    TOTAL=${#WORKERS[@]}
    log_info "Workers encontrados: $TOTAL"

    if [ "$TOTAL" -ge 1 ]; then
        kubectl label node "${WORKERS[0]}" role=frontend --overwrite 2>/dev/null || true
        kubectl taint node "${WORKERS[0]}" dedicated=frontend:NoSchedule --overwrite 2>/dev/null || true
        log_ok "Worker [${WORKERS[0]}] → role=frontend"
    fi
    if [ "$TOTAL" -ge 2 ]; then
        kubectl label node "${WORKERS[1]}" role=backend1 --overwrite 2>/dev/null || true
        kubectl taint node "${WORKERS[1]}" dedicated=backend1:NoSchedule --overwrite 2>/dev/null || true
        log_ok "Worker [${WORKERS[1]}] → role=backend1 (Backend Transaccional)"
    fi
    if [ "$TOTAL" -ge 3 ]; then
        kubectl label node "${WORKERS[2]}" role=backend2 --overwrite 2>/dev/null || true
        kubectl taint node "${WORKERS[2]}" dedicated=backend2:NoSchedule --overwrite 2>/dev/null || true
        log_ok "Worker [${WORKERS[2]}] → role=backend2 (Backend Analítico)"
    fi
    if [ "$TOTAL" -ge 4 ]; then
        kubectl label node "${WORKERS[3]}" role=database-mongo --overwrite 2>/dev/null || true
        kubectl taint node "${WORKERS[3]}" dedicated=database:NoSchedule --overwrite 2>/dev/null || true
        log_ok "Worker [${WORKERS[3]}] → role=database-mongo (MongoDB)"
    fi

    # Paso 2 — Config base con endpoints reales
    apply_base_config

    # Paso 3 — MongoDB (in-cluster si MONGO_HOST = mongodb-service)
    if [ "$MONGO_HOST" = "mongodb-service" ]; then
        log_step "Desplegando MongoDB in-cluster (EC2 dedicado)"
        kubectl apply -f "${K8S_DIR}/databases/mongodb.yaml"
        kubectl rollout status deployment/mongodb -n "$NS" --timeout=180s \
            && log_ok "MongoDB READY" || log_warn "MongoDB tardando..."
    else
        log_info "MongoDB externo (${MONGO_HOST}:${MONGO_PORT}) — no se despliega pod"
    fi

    # Paso 4 — SQL Server siempre externo en RDS (Modo 2)
    log_info "SQL Server en RDS: ${RDS_ENDPOINT}:${RDS_PORT} — conexión externa configurada ✓"

    # Paso 5 — Microservicios con aislamiento
    log_step "Desplegando Microservicios con aislamiento de nodos"

    kubectl apply -f "${K8S_DIR}/backend-transaccional/deployment.yaml"
    kubectl apply -f "${K8S_DIR}/backend-transaccional/service.yaml"
    kubectl apply -f "${K8S_DIR}/backend-transaccional/hpa.yaml" 2>/dev/null || true
    log_ok "Backend Transaccional (Spring Boot) → nodo backend1"

    kubectl apply -f "${K8S_DIR}/backend-analitico/deployment.yaml"
    kubectl apply -f "${K8S_DIR}/backend-analitico/service.yaml"
    kubectl apply -f "${K8S_DIR}/backend-analitico/hpa.yaml" 2>/dev/null || true
    log_ok "Backend Analítico (Flask) → nodo backend2"

    kubectl apply -f "${K8S_DIR}/frontend-web/deployment.yaml"
    kubectl apply -f "${K8S_DIR}/frontend-web/service.yaml"
    log_ok "Frontend Web (React/Nginx) → nodo frontend"

    # Paso 6 — Ingress
    if [ -f "${K8S_DIR}/ingress/ingress.yaml" ]; then
        kubectl apply -f "${K8S_DIR}/ingress/ingress.yaml" 2>/dev/null \
            || log_warn "Ingress omitido (requiere ingress-controller)"
    fi

    # Paso 7 — Monitoring con Helm
    if command -v helm &>/dev/null; then
        log_step "Desplegando Prometheus + Grafana"
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
        helm repo update 2>/dev/null || true
        helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
            --namespace monitoring --create-namespace \
            --values "${K8S_DIR}/monitoring/prometheus-values.yaml" \
            --timeout 5m 2>/dev/null || log_warn "Monitoring: con advertencias"
        kubectl apply -f "${K8S_DIR}/monitoring/servicemonitor-backend.yaml"   2>/dev/null || true
        kubectl apply -f "${K8S_DIR}/monitoring/servicemonitor-backend-a.yaml" 2>/dev/null || true
        kubectl apply -f "${K8S_DIR}/monitoring/alerting-rules.yaml"           2>/dev/null || true
        log_ok "Monitoring desplegado"
    else
        log_warn "Helm no encontrado — monitoring omitido"
    fi

    # Paso 8 — Esperar readiness
    wait_for "backend-transaccional" 180
    wait_for "backend-analitico" 120
    wait_for "frontend-web" 90

    # Paso 9 — Verificar conectividad interna DNS
    log_step "Verificando conectividad interna entre servicios"
    POD=$(kubectl get pods -n "$NS" -l app=backend-transaccional \
        --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$POD" ]; then
        kubectl exec "$POD" -n "$NS" -- sh -c \
            "nslookup mongodb-service 2>/dev/null | grep -q Address && echo OK" 2>/dev/null \
            && log_ok "DNS mongodb-service → resolvible ✓" \
            || log_warn "DNS mongodb-service: verificar manualmente"
    fi

    # Paso 10 — Cargar tablas y datos semilla
    seed_databases

    print_summary "2 — Orquestadores K8s"
}

# ═════════════════════════════════════════════════════════════════════════════
# MAIN
# ═════════════════════════════════════════════════════════════════════════════
case "$MODE" in
    1) mode_1_cloud_taller ;;
    2) mode_2_orquestadores ;;
    *) echo -e "${RED}Modo inválido. Usa 1 o 2.${NC}"; exit 1 ;;
esac

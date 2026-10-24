#!/usr/bin/env bash
# =============================================================================
#  🚀 VISONS S.A.C. — SCRIPT MAESTRO DE DESPLIEGUE AWS (DESDE CERO)
# =============================================================================
#  Ejecutar desde: kubernetes/
#  Uso:  bash scripts/deploy-master.sh <IP_PUBLICA_MASTER>
#  Ej:   bash scripts/deploy-master.sh 54.123.45.67
#
#  Qué hace este script:
#    1. Recibe la IP pública del nodo Master (EIP de AWS)
#    2. Inyecta esa IP en ConfigMaps (reemplaza localhost)
#    3. Despliega namespace, secrets y configmaps
#    4. Despliega MongoDB + SQL Server in-cluster y espera que estén listos
#    5. Despliega Backend Transaccional (Spring Boot) y Analítico (Flask)
#    6. Despliega Frontend Web (React/Nginx) con URL correcta
#    7. Despliega Ingress + Monitoring (Helm)
#    8. Espera que todos los pods estén Ready
#    9. Verifica DNS entre servicios
#   10. Imprime resumen con URLs de acceso
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_step()  { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"
              echo -e "${CYAN}  🎯 $1${NC}"
              echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"; }
log_info()  { echo -e "${BLUE}  ℹ  $1${NC}"; }
log_ok()    { echo -e "${GREEN}  ✅ $1${NC}"; }
log_warn()  { echo -e "${YELLOW}  ⚠  $1${NC}"; }
log_error() { echo -e "${RED}  ❌ $1${NC}"; exit 1; }

# ── Argumento: IP pública del Master ─────────────────────────────────────────
MASTER_IP="${1:-}"
if [ -z "$MASTER_IP" ]; then
    echo -e "${BOLD}Uso: bash scripts/deploy-master.sh <IP_PUBLICA_MASTER>${NC}"
    echo    "Ej:  bash scripts/deploy-master.sh 54.123.45.67"
    exit 1
fi

NS="visons-prod"
K8S_DIR="k8s"

# ════════════════════════════════════════════════════════════════════════════
# PASO 0 — Verificar prerequisites
# ════════════════════════════════════════════════════════════════════════════
log_step "0/9: Verificando prerequisites"

command -v kubectl &>/dev/null || log_error "kubectl no encontrado."
command -v sed    &>/dev/null || log_error "sed no encontrado."

if ! kubectl cluster-info &>/dev/null; then
    log_error "No se puede contactar el clúster. Revisa tu kubeconfig."
fi

log_ok "Clúster: $(kubectl config current-context)"
log_ok "IP Pública Master: $MASTER_IP"

# ════════════════════════════════════════════════════════════════════════════
# PASO 1 — Inyectar IP en ConfigMap (reemplaza localhost → IP pública)
# ════════════════════════════════════════════════════════════════════════════
log_step "1/9: Inyectando IP pública ($MASTER_IP) en ConfigMaps"

CONFIGMAP_FILE="${K8S_DIR}/02-configmaps.yaml"

# Crear una versión temporal con IPs reales para aplicar al clúster
CONFIGMAP_RENDERED=$(mktemp /tmp/configmap_rendered.XXXXXX.yaml)
sed "s|http://localhost:5173|http://${MASTER_IP}:30080|g; s|localhost|${MASTER_IP}|g" \
    "$CONFIGMAP_FILE" > "$CONFIGMAP_RENDERED"

log_ok "ConfigMap renderizado: FRONTEND_URL → http://${MASTER_IP}:30080"

# ════════════════════════════════════════════════════════════════════════════
# PASO 2 — Namespace, Secrets y ConfigMaps
# ════════════════════════════════════════════════════════════════════════════
log_step "2/9: Desplegando Namespace, Secrets y ConfigMaps"

kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
log_ok "Namespace '${NS}' listo"

kubectl apply -f "${K8S_DIR}/01-secrets.yaml"
log_ok "Secrets aplicados"

# Aplicar la versión con IP real (no modifica el archivo original)
kubectl apply -f "$CONFIGMAP_RENDERED"
rm -f "$CONFIGMAP_RENDERED"
log_ok "ConfigMaps aplicados con IP pública correcta"

# ════════════════════════════════════════════════════════════════════════════
# PASO 3 — Desplegar Bases de Datos (MongoDB + SQL Server in-cluster)
# ════════════════════════════════════════════════════════════════════════════
log_step "3/9: Desplegando Bases de Datos in-cluster (MongoDB + SQL Server)"

kubectl apply -f "${K8S_DIR}/databases/mongodb.yaml"
log_info "MongoDB 7.0 → manifest aplicado"

kubectl apply -f "${K8S_DIR}/databases/sqlserver.yaml"
log_info "SQL Server 2022 → manifest aplicado"

# Esperar MongoDB
log_info "Esperando MongoDB Ready (máx 3 min)..."
kubectl rollout status deployment/mongodb -n "$NS" --timeout=180s \
    && log_ok "MongoDB READY ✓" \
    || log_warn "MongoDB tardó más — verifica: kubectl logs -l app=mongodb -n $NS"

# Esperar SQL Server
log_info "Esperando SQL Server Ready (máx 4 min)..."
kubectl rollout status deployment/sqlserver -n "$NS" --timeout=240s \
    && log_ok "SQL Server READY ✓" \
    || log_warn "SQL Server tardó más — verifica: kubectl logs -l app=sqlserver -n $NS"

# ════════════════════════════════════════════════════════════════════════════
# PASO 4 — Backend Transaccional (Spring Boot)
# ════════════════════════════════════════════════════════════════════════════
log_step "4/9: Desplegando Backend Transaccional (Spring Boot)"

kubectl apply -f "${K8S_DIR}/backend-transaccional/deployment.yaml"
kubectl apply -f "${K8S_DIR}/backend-transaccional/service.yaml"
kubectl apply -f "${K8S_DIR}/backend-transaccional/hpa.yaml" 2>/dev/null \
    || log_warn "HPA backend-transaccional omitido (requiere metrics-server)"

log_ok "Backend Transaccional desplegado"

# ════════════════════════════════════════════════════════════════════════════
# PASO 5 — Backend Analítico (Flask/Python)
# ════════════════════════════════════════════════════════════════════════════
log_step "5/9: Desplegando Backend Analítico (Flask)"

kubectl apply -f "${K8S_DIR}/backend-analitico/deployment.yaml"
kubectl apply -f "${K8S_DIR}/backend-analitico/service.yaml"
kubectl apply -f "${K8S_DIR}/backend-analitico/hpa.yaml" 2>/dev/null \
    || log_warn "HPA backend-analitico omitido (requiere metrics-server)"

log_ok "Backend Analítico desplegado"

# ════════════════════════════════════════════════════════════════════════════
# PASO 6 — Frontend Web (React/Nginx) con URL inyectada
# ════════════════════════════════════════════════════════════════════════════
log_step "6/9: Desplegando Frontend Web (React / Nginx)"

FRONTEND_DEPLOY="${K8S_DIR}/frontend-web/deployment.yaml"

# Renderizar deployment con IP real (sin modificar el archivo fuente)
FRONTEND_RENDERED=$(mktemp /tmp/frontend_rendered.XXXXXX.yaml)
sed "s|http://localhost:[0-9]*/api/v1/analytics|http://${MASTER_IP}:30500/api/v1/analytics|g; \
     s|http://localhost:[0-9]*/api|http://${MASTER_IP}:30090/api|g; \
     s|localhost|${MASTER_IP}|g" \
    "$FRONTEND_DEPLOY" > "$FRONTEND_RENDERED"

kubectl apply -f "$FRONTEND_RENDERED"
rm -f "$FRONTEND_RENDERED"
kubectl apply -f "${K8S_DIR}/frontend-web/service.yaml"

log_ok "Frontend Web desplegado con URLs correctas"

# ════════════════════════════════════════════════════════════════════════════
# PASO 7 — Ingress y Monitoring
# ════════════════════════════════════════════════════════════════════════════
log_step "7/9: Aplicando Ingress y Monitoreo"

if [ -f "${K8S_DIR}/ingress/ingress.yaml" ]; then
    kubectl apply -f "${K8S_DIR}/ingress/ingress.yaml" 2>/dev/null \
        || log_warn "Ingress omitido (requiere ingress-controller)"
fi

if command -v helm &>/dev/null; then
    log_info "Helm detectado — desplegando Prometheus + Grafana..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update 2>/dev/null || true
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
        --namespace monitoring --create-namespace \
        --values "${K8S_DIR}/monitoring/prometheus-values.yaml" \
        --timeout 5m 2>/dev/null || log_warn "Monitoring: helm con advertencias"

    kubectl apply -f "${K8S_DIR}/monitoring/servicemonitor-backend.yaml"   2>/dev/null || true
    kubectl apply -f "${K8S_DIR}/monitoring/servicemonitor-backend-a.yaml" 2>/dev/null || true
    kubectl apply -f "${K8S_DIR}/monitoring/alerting-rules.yaml"           2>/dev/null || true
    log_ok "Monitoring desplegado"
else
    log_warn "Helm no encontrado — monitoring omitido"
fi

# ════════════════════════════════════════════════════════════════════════════
# PASO 8 — Esperar que todos los pods principales estén Ready
# ════════════════════════════════════════════════════════════════════════════
log_step "8/9: Esperando que todos los servicios estén Ready"

wait_for() {
    local name=$1 timeout=${2:-120}
    log_info "Esperando deployment/$name (máx ${timeout}s)..."
    kubectl rollout status deployment/"$name" -n "$NS" --timeout="${timeout}s" \
        && log_ok "$name → READY" \
        || log_warn "$name: aún iniciando en background"
}

wait_for "backend-transaccional" 180
wait_for "backend-analitico"     120
wait_for "frontend-web"          90

# ════════════════════════════════════════════════════════════════════════════
# PASO 9 — Verificar DNS interno
# ════════════════════════════════════════════════════════════════════════════
log_step "9/9: Verificación de conectividad DNS interna"

# Buscar un pod en Running para prueba
POD=$(kubectl get pods -n "$NS" -l app=backend-transaccional \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$POD" ]; then
    log_info "Verificando DNS desde pod: $POD"

    kubectl exec "$POD" -n "$NS" -- sh -c \
        "nslookup mongodb-service 2>/dev/null | grep -q Address && echo OK" 2>/dev/null \
        && log_ok "DNS: mongodb-service → OK ✓" \
        || log_warn "DNS: mongodb-service no pudo verificarse (puede estar OK de todas formas)"

    kubectl exec "$POD" -n "$NS" -- sh -c \
        "nslookup sqlserver-service 2>/dev/null | grep -q Address && echo OK" 2>/dev/null \
        && log_ok "DNS: sqlserver-service → OK ✓" \
        || log_warn "DNS: sqlserver-service no pudo verificarse (puede estar OK de todas formas)"
else
    log_warn "backend-transaccional aún iniciando — DNS no verificado"
fi

# ════════════════════════════════════════════════════════════════════════════
# RESUMEN FINAL
# ════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  🚀 DESPLIEGUE COMPLETADO — VISONS S.A.C.${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"

echo -e "\n${BOLD}📦 Pods en $NS:${NC}"
kubectl get pods -n "$NS" -o wide

echo -e "\n${BOLD}🔌 Servicios:${NC}"
kubectl get svc -n "$NS"

echo -e "\n${BOLD}🌐 URLs de acceso (IP: ${MASTER_IP}):${NC}"
echo -e "  Frontend Web:            ${GREEN}http://${MASTER_IP}:30080${NC}"
echo -e "  Backend Transaccional:   ${GREEN}http://${MASTER_IP}:30090/api/v1${NC}"
echo -e "  Backend Analítico:       ${GREEN}http://${MASTER_IP}:30500/api/v1/analytics${NC}"
echo -e "  Grafana:                 ${GREEN}http://${MASTER_IP}:30300${NC}  (admin / prom-operator)"
echo -e "  Prometheus:              ${GREEN}http://${MASTER_IP}:30091${NC}"

echo -e "\n${BOLD}🛢  Bases de Datos (DNS interno del clúster):${NC}"
echo -e "  MongoDB:    ${CYAN}mongodb://admin:admin123@mongodb-service:27017/Visons?authSource=admin${NC}"
echo -e "  SQL Server: ${CYAN}sqlserver-service:1433  DB=Visons  user=sa${NC}"

echo -e "\n${BOLD}🔍 Diagnóstico rápido:${NC}"
echo    "  kubectl get pods -n $NS -o wide"
echo    "  kubectl logs -l app=backend-transaccional -n $NS --tail=50"
echo    "  kubectl logs -l app=backend-analitico -n $NS --tail=50"
echo    "  kubectl logs -l app=mongodb -n $NS --tail=30"
echo    "  kubectl logs -l app=sqlserver -n $NS --tail=30"
echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"

#!/usr/bin/env bash
# =============================================================================
# DESPLIEGUE OFICIAL EN AWS (EC2 / EKS) — PLATAFORMA VISONS S.A.C.
# =============================================================================
# Despliega los microservicios en el clúster multinodo de AWS:
#   1. Aislamiento de nodos (Labels + Taints en Worker Nodes dedicados)
#   2. Namespace, Secrets y ConfigMaps desacoplados
#   3. Conexión externa a Persistencia Políglota (RDS SQL Server + Mongo EC2/Atlas)
#      (NO despliega bases de datos locales in-cluster)
#   4. Stack de Observabilidad Completo (Prometheus Operator, Grafana, AlertManager)
#   5. Microservicios con autoescalado (HPA) y ServiceMonitors
# =============================================================================

set -euo pipefail

# ── Colores para salida de consola ───────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✅ OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[⚠️  WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[❌ ERROR]${NC} $1"; }
log_step()    { 
    echo -e "\n${CYAN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN} 🎯 $1${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════════${NC}"
}

# ── 1. Verificación de Conexión al Clúster ─────────────────────────────────────
check_cluster() {
    log_step "1/7: Verificando conexión al clúster de AWS"
    if ! kubectl cluster-info &>/dev/null; then
        log_error "No se puede contactar el clúster Kubernetes. Revisa tu kubeconfig / conexión a AWS."
        exit 1
    fi
    log_success "Conexión establecida con el clúster: $(kubectl config current-context)"
}

# ── 2. Aislamiento Físico de Nodos (Labels & Taints) ──────────────────────────
isolate_nodes() {
    log_step "2/7: Aplicando Aislamiento de Nodos (Node Labels y Taints dedicados)"
    
    # 1. Asegurar que el Master no tenga taints de aplicaciones
    local master_nodes=($(kubectl get nodes --no-headers | grep -E 'control-plane|master' | awk '{print $1}'))
    for m in "${master_nodes[@]}"; do
        kubectl taint node "$m" dedicated- 2>/dev/null || true
        kubectl label node "$m" node-role.kubernetes.io/master=true --overwrite 2>/dev/null || true
        log_info "Master [$m] protegido sin taints de aplicaciones."
    done

    # 2. Asignar roles dedicados a los workers
    local workers=($(kubectl get nodes --no-headers | grep -vE 'control-plane|master' | awk '{print $1}'))
    local total=${#workers[@]}
    log_info "Workers detectados para aislamiento: $total"

    if [ "$total" -ge 3 ]; then
        # Worker 1: Frontend Web
        kubectl label node "${workers[0]}" role=frontend --overwrite
        kubectl taint node "${workers[0]}" dedicated=frontend:NoSchedule --overwrite 2>/dev/null || true
        log_success "Worker 1 [${workers[0]}]: role=frontend | taint: dedicated=frontend:NoSchedule"

        # Worker 2: Backend Transaccional (Spring Boot Java 25)
        kubectl label node "${workers[1]}" role=backend1 --overwrite
        kubectl taint node "${workers[1]}" dedicated=backend1:NoSchedule --overwrite 2>/dev/null || true
        log_success "Worker 2 [${workers[1]}]: role=backend1 | taint: dedicated=backend1:NoSchedule"

        # Worker 3: Backend Analítico (Python 3.12 Flask)
        kubectl label node "${workers[2]}" role=backend2 --overwrite
        kubectl taint node "${workers[2]}" dedicated=backend2:NoSchedule --overwrite 2>/dev/null || true
        log_success "Worker 3 [${workers[2]}]: role=backend2 | taint: dedicated=backend2:NoSchedule"
    fi
}

# ── 3. Namespace, Secrets y ConfigMaps ────────────────────────────────────────
deploy_config() {
    log_step "3/7: Desplegando Namespace, Secrets y ConfigMaps de Producción"
    kubectl apply -f k8s/00-namespace.yaml
    kubectl apply -f k8s/01-secrets.yaml
    kubectl apply -f k8s/02-configmaps.yaml
    log_success "Configuraciones base desplegadas en namespace 'visons-prod'"
}

# ── 4. Stack de Observabilidad con Helm ────────────────────────────────────────
deploy_monitoring() {
    log_step "4/7: Desplegando Stack de Observabilidad (Prometheus & Grafana)"
    if ! command -v helm &>/dev/null; then
        log_info "Helm no detectado. Instalando Helm v3..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    if [ -f "/etc/rancher/k3s/k3s.yaml" ]; then
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    fi

    if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    fi
    helm repo update

    log_info "Instalando/Actualizando kube-prometheus-stack..."
    helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --values k8s/monitoring/prometheus-values.yaml \
        --timeout 5m || log_warn "Helm completó con advertencias, continuando con microservicios..."

    log_success "Observabilidad configurada en namespace 'monitoring'"
}

# ── 5. Despliegue de Microservicios & Autoscaling (HPA) ────────────────────────
deploy_services() {
    log_step "5/7: Desplegando Microservicios de Visons S.A.C."
    
    log_info "Desplegando Backend Transaccional (Spring Boot Java 25)..."
    kubectl apply -f k8s/backend-transaccional/deployment.yaml
    kubectl apply -f k8s/backend-transaccional/service.yaml
    kubectl apply -f k8s/backend-transaccional/hpa.yaml

    log_info "Desplegando Backend Analítico (Python 3.12 Flask)..."
    kubectl apply -f k8s/backend-analitico/deployment.yaml
    kubectl apply -f k8s/backend-analitico/service.yaml
    kubectl apply -f k8s/backend-analitico/hpa.yaml

    log_info "Desplegando Frontend Web (React + Vite)..."
    kubectl apply -f k8s/frontend-web/deployment.yaml
    kubectl apply -f k8s/frontend-web/service.yaml

    log_info "Desplegando Ingress Controller / Gateway..."
    kubectl apply -f k8s/ingress/ingress.yaml

    log_success "Microservicios y políticas de autoescalado HPA aplicados"
}

# ── 6. ServiceMonitors y Reglas de Alerta ─────────────────────────────────────
apply_monitoring_rules() {
    log_step "6/7: Vinculando ServiceMonitors y Alertas de Prometheus"
    kubectl apply -f k8s/monitoring/servicemonitor-backend.yaml
    kubectl apply -f k8s/monitoring/servicemonitor-backend-a.yaml
    kubectl apply -f k8s/monitoring/alerting-rules.yaml
    log_success "ServiceMonitors indexados por Prometheus Operator"
}

# ── 7. Verificación Final ─────────────────────────────────────────────────────
verify_status() {
    log_step "7/7: Verificación del Estado del Clúster"
    echo -e "${BOLD}Pods en namespace visons-prod:${NC}"
    kubectl get pods -n visons-prod -o wide
    
    echo -e "\n${BOLD}Servicios en visons-prod:${NC}"
    kubectl get svc -n visons-prod

    echo -e "\n${BOLD}Políticas de Autoescalado (HPA):${NC}"
    kubectl get hpa -n visons-prod

    log_success "¡Despliegue en AWS completado exitosamente!"
    echo -e "\n${CYAN}Puertos NodePort asignados:${NC}"
    echo -e " - Frontend Web:            NodePort 30080"
    echo -e " - Backend Transaccional:   NodePort 30090"
    echo -e " - Backend Analítico:       NodePort 30500"
    echo -e " - Grafana:                 NodePort 30300"
    echo -e " - Prometheus:              NodePort 30091"
}

main() {
    check_cluster
    isolate_nodes
    deploy_config
    deploy_monitoring
    deploy_services
    apply_monitoring_rules
    verify_status
}

main "$@"

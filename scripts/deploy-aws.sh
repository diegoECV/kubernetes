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
    local nodes=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    local total=${#nodes[@]}

    log_info "Total de nodos detectados en el clúster: $total"

    if [ "$total" -ge 3 ]; then
        log_info "Asignando roles dedicados y taints a los 3 nodos principales:"
        
        # Nodo 1: Frontend Web
        kubectl label node "${nodes[0]}" role=frontend --overwrite
        kubectl taint node "${nodes[0]}" dedicated=frontend:NoSchedule --overwrite 2>/dev/null || true
        log_success "Nodo 1 [${nodes[0]}]: role=frontend | taint: dedicated=frontend:NoSchedule"

        # Nodo 2: Backend Transaccional (Spring Boot Java 25)
        kubectl label node "${nodes[1]}" role=backend1 --overwrite
        kubectl taint node "${nodes[1]}" dedicated=backend1:NoSchedule --overwrite 2>/dev/null || true
        log_success "Nodo 2 [${nodes[1]}]: role=backend1 | taint: dedicated=backend1:NoSchedule"

        # Nodo 3: Backend Analítico (Python 3.12 Flask)
        kubectl label node "${nodes[2]}" role=backend2 --overwrite
        kubectl taint node "${nodes[2]}" dedicated=backend2:NoSchedule --overwrite 2>/dev/null || true
        log_success "Nodo 3 [${nodes[2]}]: role=backend2 | taint: dedicated=backend2:NoSchedule"
    else
        log_warn "Menos de 3 nodos detectados ($total). Etiquetando nodos disponibles sin taints estrictos..."
        for idx in "${!nodes[@]}"; do
            case $idx in
                0) kubectl label node "${nodes[$idx]}" role=frontend --overwrite ;;
                1) kubectl label node "${nodes[$idx]}" role=backend1 --overwrite ;;
                2) kubectl label node "${nodes[$idx]}" role=backend2 --overwrite ;;
            esac
        done
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
    if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    fi
    helm repo update

    if helm list -n monitoring 2>/dev/null | grep -q "monitoring"; then
        log_info "Actualizando kube-prometheus-stack..."
        helm upgrade monitoring prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            --values k8s/monitoring/prometheus-values.yaml \
            --wait --timeout 8m
    else
        log_info "Instalando kube-prometheus-stack..."
        helm install monitoring prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            --create-namespace \
            --values k8s/monitoring/prometheus-values.yaml \
            --wait --timeout 8m
    fi
    log_success "Observabilidad desplegada en namespace 'monitoring'"
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

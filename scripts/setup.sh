#!/usr/bin/env bash
# =============================================================================
# SETUP AUTOMATIZADO — PLATAFORMA VISONS S.A.C. EN KUBERNETES
# =============================================================================
# Despliega el clúster local Minikube con:
#   1. Stack de Microservicios (Spring Boot WebFlux Java 25 + Flask Python 3.12 + Frontend Web)
#   2. Persistencia Políglota (SQL Server 2022 + MongoDB 7.0)
#   3. Stack de Observabilidad Completo (Prometheus Operator, Grafana, AlertManager, NodeExporter)
#   4. Autoescalado Horizontal de Pods (HPA) con Metrics-Server
#   5. Reglas de Alerta & Dashboard Ejecutivo en Grafana
# =============================================================================

set -euo pipefail

# ── Colores para la salida en consola ─────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
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

# ── 1. Verificación de Prerrequisitos ──────────────────────────────────────────
check_prerequisites() {
    log_step "1/8: Verificando herramientas instaladas"
    local tools=("docker" "minikube" "kubectl" "helm" "curl")
    local missing=()

    for tool in "${tools[@]}"; do
        if command -v "$tool" &>/dev/null; then
            log_success "$tool detectado: $(command -v "$tool")"
        else
            log_error "$tool NO está instalado en el sistema"
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Faltan las siguientes herramientas requeridas: ${missing[*]}"
        exit 1
    fi
}

# ── 2. Inicialización de Minikube ──────────────────────────────────────────────
start_minikube() {
    log_step "2/8: Comprobando estado del clúster Minikube"
    if minikube status &>/dev/null; then
        log_success "Minikube se encuentra en ejecución activa"
    else
        log_info "Iniciando Minikube con 4 CPUs y 6GB de memoria..."
        minikube start \
            --nodes=3 \
            --cpus=4 \
            --memory=6144 \
            --disk-size=25g \
            --driver=docker
        log_success "Minikube multinodo iniciado exitosamente"
    fi

    log_info "Habilitando complementos requeridos: metrics-server e ingress..."
    minikube addons enable metrics-server
    minikube addons enable ingress
    log_success "Complementos de Minikube activados"
}

# ── 3. Creación del Namespace & Recursos Base ─────────────────────────────────
deploy_base() {
    log_step "3/8: Creando Namespace, Secrets, ConfigMaps y Aislamiento de Nodos"
    kubectl apply -f k8s/00-namespace.yaml
    kubectl apply -f k8s/01-secrets.yaml
    kubectl apply -f k8s/02-configmaps.yaml

    # Etiquetar nodos con roles dedicados (1 rol por nodo para aislamiento real)
    log_info "Etiquetando nodos con roles de aislamiento (frontend, backend1, backend2)..."
    local node_list=($(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'))
    if [ ${#node_list[@]} -ge 3 ]; then
        kubectl label node "${node_list[0]}" role=frontend --overwrite
        kubectl label node "${node_list[1]}" role=backend1 --overwrite
        kubectl label node "${node_list[2]}" role=backend2 --overwrite
        log_success "Nodos etiquetados: ${node_list[0]}=frontend, ${node_list[1]}=backend1, ${node_list[2]}=backend2"
    else
        log_warn "Clúster con menos de 3 nodos detectados (${#node_list[@]}). Etiquetando nodos disponibles..."
        for idx in "${!node_list[@]}"; do
            case $idx in
                0) kubectl label node "${node_list[$idx]}" role=frontend --overwrite ;;
                1) kubectl label node "${node_list[$idx]}" role=backend1 --overwrite ;;
                2) kubectl label node "${node_list[$idx]}" role=backend2 --overwrite ;;
            esac
        done
    fi
    log_success "Configuración base y etiquetas de aislamiento aplicadas"
}

# ── 4. Despliegue del Stack de Observabilidad con Helm ────────────────────────
install_monitoring() {
    log_step "4/8: Desplegando Prometheus Operator, Grafana y AlertManager"
    if ! helm repo list 2>/dev/null | grep -q "prometheus-community"; then
        log_info "Agregando repositorio Helm de prometheus-community..."
        helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
    fi
    helm repo update

    if helm list -n monitoring 2>/dev/null | grep -q "monitoring"; then
        log_info "El stack de monitoreo ya existe. Actualizando configuración..."
        helm upgrade monitoring prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            --values k8s/monitoring/prometheus-values.yaml \
            --wait \
            --timeout 8m
    else
        log_info "Instalando kube-prometheus-stack (esperando despliegue de CRDs)..."
        helm install monitoring prometheus-community/kube-prometheus-stack \
            --namespace monitoring \
            --create-namespace \
            --values k8s/monitoring/prometheus-values.yaml \
            --wait \
            --timeout 8m
    fi
    log_success "Stack de observabilidad instalado y operativo"
}

# ── 5. Despliegue de Bases de Datos In-Cluster (Opcional/Auto) ─────────────────
deploy_databases() {
    log_step "5/8: Desplegando Bases de Datos Políglotas (SQL Server & MongoDB)"
    kubectl apply -f k8s/databases/sqlserver.yaml
    kubectl apply -f k8s/databases/mongodb.yaml
    log_success "Manifiestos de SQL Server y MongoDB aplicados"
}

# ── 6. Despliegue de Microservicios & Autoscaling ─────────────────────────────
deploy_microservices() {
    log_step "6/8: Desplegando Microservicios de Visons S.A.C."
    log_info "Desplegando Backend Transaccional (Spring Boot Java 25)..."
    kubectl apply -f k8s/backend-transaccional/deployment.yaml
    kubectl apply -f k8s/backend-transaccional/service.yaml
    kubectl apply -f k8s/backend-transaccional/hpa.yaml

    log_info "Desplegando Backend Analítico (Flask Python 3.12)..."
    kubectl apply -f k8s/backend-analitico/deployment.yaml
    kubectl apply -f k8s/backend-analitico/service.yaml
    kubectl apply -f k8s/backend-analitico/hpa.yaml

    log_info "Desplegando Frontend Web (React + Vite)..."
    kubectl apply -f k8s/frontend-web/deployment.yaml
    kubectl apply -f k8s/frontend-web/service.yaml

    log_info "Desplegando Ingress Gateway..."
    kubectl apply -f k8s/ingress/ingress.yaml

    log_success "Microservicios y políticas de autoescalado desplegados"
}

# ── 7. Aplicar ServiceMonitors y Reglas de Alerta ─────────────────────────────
apply_monitoring_rules() {
    log_step "7/8: Vinculando ServiceMonitors y Reglas de Alerta de Prometheus"
    kubectl apply -f k8s/monitoring/servicemonitor-backend.yaml
    kubectl apply -f k8s/monitoring/servicemonitor-backend-a.yaml
    kubectl apply -f k8s/monitoring/alerting-rules.yaml
    log_success "ServiceMonitors y PrometheusRules indexados por el Prometheus Operator"
}

# ── 8. Importar Dashboard de Grafana en Vivo ──────────────────────────────────
import_dashboard() {
    log_step "8/8: Importando Dashboard Ejecutivo en Grafana"
    log_info "Esperando disponibilidad del pod de Grafana..."
    kubectl wait --for=condition=ready pod \
        -l "app.kubernetes.io/name=grafana" \
        -n monitoring \
        --timeout=90s || log_warn "Grafana aún iniciando..."

    kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring &
    local pf_pid=$!
    sleep 4

    if [ -f "k8s/monitoring/grafana-dashboard.json" ]; then
        local payload
        payload=$(cat k8s/monitoring/grafana-dashboard.json)
        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "{\"dashboard\": ${payload}, \"overwrite\": true, \"folderId\": 0}" \
            "http://admin:visons2026@localhost:3000/api/dashboards/db" > /dev/null && \
            log_success "Dashboard 'Visons S.A.C. — Observabilidad' importado en Grafana" || \
            log_warn "No se pudo sincronizar por API directa; se cargará automáticamente vía provider"
    fi
    kill $pf_pid 2>/dev/null || true
}

# ── Resumen y URLs ────────────────────────────────────────────────────────────
print_summary() {
    local minikube_ip
    minikube_ip=$(minikube ip 2>/dev/null || echo "127.0.0.1")

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   🎉 PLATAFORMA VISONS S.A.C. DESPLEGADA EXITOSAMENTE         ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}🌐 URLs de Servicios (Acceso Directo NodePort):${NC}"
    echo -e "  • Frontend Web:             ${CYAN}http://${minikube_ip}:30080${NC}"
    echo -e "  • Backend Transaccional:    ${CYAN}http://${minikube_ip}:30090/actuator/health${NC}"
    echo -e "  • Backend Analítico:        ${CYAN}http://${minikube_ip}:30500/health${NC}"
    echo -e "  • Grafana Dashboard:        ${CYAN}http://${minikube_ip}:30300${NC} (admin / visons2026)"
    echo ""
    echo -e "  ${BOLD}⚡ Para acceder desde el navegador local usando port-forward:${NC}"
    echo -e "  Ejecuta: ${YELLOW}bash scripts/port-forward.sh${NC}"
    echo ""
    echo -e "  ${BOLD}🧪 Para ejecutar pruebas de carga y estrés (HPA Demo):${NC}"
    echo -e "  Ejecuta: ${YELLOW}bash load-testing/stress-test.sh${NC}"
    echo ""
}

main() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    check_prerequisites
    start_minikube
    deploy_base
    install_monitoring
    deploy_databases
    deploy_microservices
    apply_monitoring_rules
    import_dashboard
    print_summary
}

main "$@"

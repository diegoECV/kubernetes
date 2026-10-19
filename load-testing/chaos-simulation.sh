#!/usr/bin/env bash
# =============================================================================
# SIMULACIÓN DE CAOS & RESILIENCIA — VISONS S.A.C.
# =============================================================================
# Demuestra las capacidades de autoreparación (Self-Healing) y Alertas en K8s:
#   1. Caída intencional de un pod (Self-Healing de Kubernetes)
#   2. Simulación de corte de servicio para disparo de Alerta en AlertManager
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

test_self_healing() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  🛡️ PRUEBA 1: AUTO-RECUPERACIÓN (SELF-HEALING)                 ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo "Identificando pod actual de backend-transaccional..."
    local pod_name
    pod_name=$(kubectl get pods -n visons-prod -l app=backend-transaccional -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -z "$pod_name" ]; then
        echo -e "${RED}No se encontró ningún pod de backend-transaccional corriendo.${NC}"
        return
    fi

    echo -e "Eliminando forzosamente el pod: ${YELLOW}${pod_name}${NC} ..."
    kubectl delete pod "$pod_name" -n visons-prod --now

    echo -e "${GREEN}Verificando la reacción del ReplicaSet de Kubernetes:${NC}"
    sleep 2
    kubectl get pods -n visons-prod -l app=backend-transaccional
    echo -e "${GREEN}✅ El ReplicaSet detectó la muerte del pod y aprovisionó uno nuevo de inmediato.${NC}"
}

test_alerting() {
    echo ""
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  🚨 PRUEBA 2: DISPARO DE ALERTAS (PROMETHEUS & ALERTMANAGER)  ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo "Escalando backend-transaccional a 0 réplicas temporalmente..."
    kubectl scale deployment backend-transaccional --replicas=0 -n visons-prod

    echo -e "${YELLOW}👁️ Abre Prometheus (http://localhost:9091/alerts) para ver la regla 'BackendTransaccionalDown'.${NC}"
    echo "Esperando 35 segundos para que la condición de alerta ('for: 30s') se cumpla..."
    sleep 35

    echo -e "${RED}Comprobando estado en Prometheus...${NC}"
    echo -e "Restableciendo el servicio a 1 réplica normal..."
    kubectl scale deployment backend-transaccional --replicas=1 -n visons-prod
    kubectl rollout status deployment/backend-transaccional -n visons-prod --timeout=60s
    echo -e "${GREEN}✅ Servicio restaurado. La alerta volverá a estado VERDE (Resolved).${NC}"
}

ACTION="${1:-all}"
case "$ACTION" in
    healing)
        test_self_healing
        ;;
    alert)
        test_alerting
        ;;
    all)
        test_self_healing
        test_alerting
        ;;
    *)
        echo "Uso: $0 {healing|alert|all}"
        exit 1
        ;;
esac

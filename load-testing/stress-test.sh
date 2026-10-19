#!/usr/bin/env bash
# =============================================================================
# STRESS TESTING & GENERADOR DE CARGA — VISONS S.A.C.
# =============================================================================
# Genera tráfico real concurrente para observar en vivo:
#   1. Gráficas de Throughput y Latencia (p50, p95, p99) en Grafana
#   2. Activación automática del Horizontal Pod Autoscaler (HPA de 1 a 5 pods)
#   3. Comportamiento reactivo no bloqueante de Spring Boot WebFlux vs Flask
#
# USO:
#   bash load-testing/stress-test.sh storm 600        # Tormenta de peticiones (Dispara HPA)
#   bash load-testing/stress-test.sh transaccional 100 # Carga al API Transaccional
#   bash load-testing/stress-test.sh analytics 50      # Carga al Motor Analítico
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

MINIKUBE_IP=$(minikube ip 2>/dev/null || echo "127.0.0.1")
TX_URL="http://${MINIKUBE_IP}:30090"
AN_URL="http://${MINIKUBE_IP}:30500"

# Si los NodePorts no responden directamente, usar localhost vía port-forward
if ! curl -s -m 1 "${TX_URL}/actuator/health" &>/dev/null; then
    TX_URL="http://localhost:9090"
    AN_URL="http://localhost:5000"
fi

run_storm() {
    local iterations=${1:-500}
    echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  💥 CASUÍSTICA: TORMENTA DE REQUESTS & AUTOESCALADO (HPA)     ║${NC}"
    echo -e "${RED}║  Disparando ${iterations} peticiones concurrentes a la plataforma       ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}👁️  OBSERVA EN TU DASHBOARD DE GRAFANA (http://localhost:3000):${NC}"
    echo "   1. Panel: '📈 Peticiones HTTP por Segundo (RPS)' ➜ Pico inmediato"
    echo "   2. Panel: '⚡ Uso de CPU vs Límites por Pod' ➜ Supera el 70%"
    echo "   3. Panel: '🔢 Réplicas HPA — backend-transaccional' ➜ Escala de 1 a 2, 3... hasta 5 pods"
    echo ""
    read -p "Presiona ENTER para iniciar la tormenta de carga... " -r

    echo -e "\n${CYAN}Generando tráfico concurrente masivo en paralelo...${NC}"
    local pids=()
    local count=0

    for i in $(seq 1 "$iterations"); do
        # Enviar petición a salud/métricas y analítica
        (
            curl -s -o /dev/null -w "%{http_code}" "${TX_URL}/actuator/prometheus" >/dev/null 2>&1
            curl -s -o /dev/null -w "%{http_code}" "${AN_URL}/api/v1/analytics/dashboard/kpis" >/dev/null 2>&1
        ) &
        pids+=($!)
        count=$((count + 1))

        # Controlar lote de concurrencia a 25 workers paralelos
        if (( count % 25 == 0 )); then
            for pid in "${pids[@]}"; do
                wait "$pid" 2>/dev/null || true
            done
            pids=()
            echo -e "  [${count}/${iterations}] Solicitudes enviadas... Verificando CPU y HPA"
        fi
    done

    # Esperar los restantes
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    echo ""
    echo -e "${GREEN}✅ Tormenta completada. Estado actual del autoscaler (HPA):${NC}"
    kubectl get hpa -n visons-prod || true
    echo ""
    echo -e "Pods activos en el clúster:"
    kubectl get pods -n visons-prod -l app=backend-transaccional
}

run_transaccional() {
    local iterations=${1:-100}
    echo -e "${BLUE}=== Evaluando Backend Transaccional (Spring Boot Java 25) ===${NC}"
    for i in $(seq 1 "$iterations"); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "${TX_URL}/actuator/health")
        echo -e "  [${i}/${iterations}] Endpoint /actuator/health -> HTTP ${code}"
        sleep 0.05
    done
    echo -e "${GREEN}Evaluación finalizada.${NC}"
}

run_analytics() {
    local iterations=${1:-50}
    echo -e "${MAGENTA}=== Evaluando Backend Analítico (Flask Python 3.12) ===${NC}"
    for i in $(seq 1 "$iterations"); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" "${AN_URL}/health")
        echo -e "  [${i}/${iterations}] Endpoint /health -> HTTP ${code}"
        sleep 0.08
    done
    echo -e "${GREEN}Evaluación finalizada.${NC}"
}

ACTION="${1:-storm}"
NUM="${2:-300}"

case "$ACTION" in
    storm)
        run_storm "$NUM"
        ;;
    transaccional|tx)
        run_transaccional "$NUM"
        ;;
    analytics|an)
        run_analytics "$NUM"
        ;;
    *)
        echo "Uso: $0 {storm|transaccional|analytics} [iteraciones]"
        exit 1
        ;;
esac

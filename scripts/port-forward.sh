#!/usr/bin/env bash
# =============================================================================
# PORT-FORWARD MULTIPLEXADO — VISONS S.A.C.
# =============================================================================
# Conecta todos los servicios del clúster a los puertos de tu máquina local
# Compatible de forma nativa con Linux, WSL (Windows) y macOS.
#
# USO:
#   bash scripts/port-forward.sh          # Inicia todos los port-forwards
#   bash scripts/port-forward.sh status   # Muestra el estado actual
#   bash scripts/port-forward.sh stop     # Detiene los procesos activos
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PID_FILE="/tmp/visons-portforward.pids"
LOG_DIR="/tmp/visons-portforward-logs"
mkdir -p "$LOG_DIR"

detect_environment() {
    if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ "$(uname)" == "Darwin" ]]; then
        echo "macos"
    else
        echo "linux"
    fi
}

ENV_TYPE=$(detect_environment)
BIND_ADDRESS="127.0.0.1"
if [[ "$ENV_TYPE" == "wsl" ]]; then
    BIND_ADDRESS="0.0.0.0"
fi

# Formato: "identificador|namespace|servicio|puerto_local|puerto_remoto|descripcion"
SERVICES=(
    "grafana|monitoring|monitoring-grafana|3000|80|📊 Grafana Dashboards"
    "prometheus|monitoring|monitoring-kube-prometheus-prometheus|9091|9090|🔥 Prometheus Engine"
    "backend-tx|visons-prod|backend-transaccional-service|9090|9090|☕ Backend Transaccional (Spring Boot)"
    "backend-an|visons-prod|backend-analitico-service|5000|5000|🐍 Backend Analítico (Flask)"
    "frontend|visons-prod|frontend-web-service|8080|80|🌐 Frontend Web (React)"
    "sqlserver|visons-prod|sqlserver-service|1433|1433|🗄️ SQL Server Database"
    "mongodb|visons-prod|mongodb-service|27017|27017|🍃 MongoDB Database"
)

stop_port_forwards() {
    echo -e "${YELLOW}Deteniendo port-forwards anteriores...${NC}"
    if [ -f "$PID_FILE" ]; then
        while read -r pid; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
    fi
    pkill -f "kubectl port-forward.*(visons-prod|monitoring)" 2>/dev/null || true
    echo -e "${GREEN}Todos los túneles han sido detenidos.${NC}"
}

status_port_forwards() {
    echo -e "${CYAN}=== ESTADO DE PUERTOS Y TÚNELES VISONS S.A.C. ===${NC}"
    for item in "${SERVICES[@]}"; do
        IFS='|' read -r id ns svc local_port remote_port desc <<< "$item"
        if nc -z "$BIND_ADDRESS" "$local_port" 2>/dev/null || curl -s -m 1 "http://localhost:${local_port}" &>/dev/null; then
            echo -e "  ${desc}: ${GREEN}ACTIVO${NC} (http://localhost:${local_port})"
        else
            echo -e "  ${desc}: ${RED}INACTIVO${NC} (Puerto ${local_port})"
        fi
    done
}

start_port_forwards() {
    stop_port_forwards
    echo ""
    echo -e "${CYAN}Iniciando túneles port-forward en segundo plano (Bind: ${BIND_ADDRESS})...${NC}"

    touch "$PID_FILE"
    for item in "${SERVICES[@]}"; do
        IFS='|' read -r id ns svc local_port remote_port desc <<< "$item"
        local log_file="${LOG_DIR}/${id}.log"
        
        # Verificar si el servicio existe antes de conectar
        if kubectl get svc "$svc" -n "$ns" &>/dev/null; then
            kubectl port-forward --address "$BIND_ADDRESS" "svc/${svc}" "${local_port}:${remote_port}" -n "$ns" > "$log_file" 2>&1 &
            local pid=$!
            echo "$pid" >> "$PID_FILE"
            echo -e "  ${GREEN}✓${NC} Conectado: ${BOLD}${desc}${NC} ➜ ${CYAN}http://localhost:${local_port}${NC}"
        else
            echo -e "  ${YELLOW}⚠${NC} Omitido: ${svc} en ${ns} no encontrado aún."
        fi
    done

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}🚀 SERVICIOS DISPONIBLES EN TU NAVEGADOR:${NC}"
    echo -e "  • 📊 Grafana:             ${CYAN}http://localhost:3000${NC} (admin / visons2026)"
    echo -e "  • 🔥 Prometheus:          ${CYAN}http://localhost:9091${NC}"
    echo -e "  • ☕ Backend Transaccional: ${CYAN}http://localhost:9090/actuator/health${NC}"
    echo -e "  • 🐍 Backend Analítico:    ${CYAN}http://localhost:5000/health${NC}"
    echo -e "  • 🌐 Frontend Web:         ${CYAN}http://localhost:8080${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════════${NC}"
    echo -e "Para detener todos los túneles ejecuta: ${YELLOW}bash scripts/port-forward.sh stop${NC}"
}

case "${1:-start}" in
    start)
        start_port_forwards
        ;;
    stop)
        stop_port_forwards
        ;;
    status)
        status_port_forwards
        ;;
    *)
        echo "Uso: $0 {start|stop|status}"
        exit 1
        ;;
esac

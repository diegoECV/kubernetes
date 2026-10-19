#!/usr/bin/env bash
# =============================================================================
# TEARDOWN — LIMPIEZA TOTAL DEL ENTORNO VISONS S.A.C.
# =============================================================================
# Detiene túneles, desinstala releases de Helm y purga recursos de Kubernetes
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${RED}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║   DESMANTELAMIENTO DEL ENTORNO KUBERNETES VISONS S.A.C.        ║${NC}"
echo -e "${RED}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Detener port-forwards
echo -e "${YELLOW}[1/4] Deteniendo túneles port-forward...${NC}"
bash "${SCRIPT_DIR}/port-forward.sh" stop 2>/dev/null || true

# 2. Eliminar microservicios y namespace
echo -e "${YELLOW}[2/4] Eliminando recursos en namespace 'visons-prod'...${NC}"
kubectl delete namespace visons-prod --timeout=60s 2>/dev/null || true

# 3. Desinstalar Helm de monitoreo
echo -e "${YELLOW}[3/4] Desinstalando stack de monitoreo (Helm)...${NC}"
helm uninstall monitoring -n monitoring 2>/dev/null || true
kubectl delete namespace monitoring --timeout=60s 2>/dev/null || true

# 4. Limpieza de temporales
echo -e "${YELLOW}[4/4] Limpiando archivos temporales...${NC}"
rm -rf /tmp/visons-portforward* /tmp/visons-k8s* 2>/dev/null || true

echo ""
echo -e "${GREEN}✅ El clúster y los recursos de Visons S.A.C. han sido limpiados con éxito.${NC}"

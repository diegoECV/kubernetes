#!/bin/bash
# =============================================================================
# SCRIPT DE POBLADO AUTOMÁTICO DE BASES DE DATOS (SEEDER) — VISONS S.A.C.
# =============================================================================
# Pobla:
#  1. MongoDB en Kubernetes: 16 colecciones (usuarios, productos, inspecciones, etc.)
#  2. AWS RDS SQL Server: 11 tablas de negocio + esquema de control (pedidos, despachos, etc.)
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=====================================================================${NC}"
echo -e "${BLUE}  🚀 INICIALIZADOR Y SEEDER DE BASES DE DATOS - VISONS S.A.C.       ${NC}"
echo -e "${BLUE}=====================================================================${NC}"

# Variables de conexión (ajustables por parámetro o variables de entorno)
RDS_ENDPOINT="${RDS_ENDPOINT:-visonsdb.ct6imgsdpqef.us-east-1.rds.amazonaws.com}"
RDS_USER="${RDS_USER:-admin}"
RDS_PASSWORD="${RDS_PASSWORD:-diego1416}"

MONGO_USER="${MONGO_USER:-admin}"
MONGO_PASSWORD="${MONGO_PASSWORD:-admin123}"
NAMESPACE="${NAMESPACE:-visons-prod}"

echo -e "${YELLOW}Configuración detectada:${NC}"
echo " • RDS SQL Server: $RDS_ENDPOINT (User: $RDS_USER)"
echo " • MongoDB Pod   : $NAMESPACE / deployment/mongodb"
echo "---------------------------------------------------------------------"

# 1. Localizar o descargar archivos semilla
TMP_DIR="/tmp/visons_seed"
mkdir -p "$TMP_DIR"

MONGO_FILE=""
if [ -f "k8s/databases/init/Visons_mongodb_completo.js" ]; then
    MONGO_FILE="k8s/databases/init/Visons_mongodb_completo.js"
elif [ -f "$HOME/FN1/database-p/init/Visons_mongodb_completo.js" ]; then
    MONGO_FILE="$HOME/FN1/database-p/init/Visons_mongodb_completo.js"
else
    echo -e "${YELLOW}Descargando script MongoDB desde GitHub...${NC}"
    curl -sSL "https://raw.githubusercontent.com/diegoECV/FN1/main/database-p/init/Visons_mongodb_completo.js" -o "$TMP_DIR/Visons_mongodb_completo.js"
    MONGO_FILE="$TMP_DIR/Visons_mongodb_completo.js"
fi

SQL_FILE=""
if [ -f "k8s/databases/init/Visons_sqlserver_completo.sql" ]; then
    SQL_FILE="k8s/databases/init/Visons_sqlserver_completo.sql"
elif [ -f "$HOME/FN1/database-p/init/Visons_sqlserver_completo.sql" ]; then
    SQL_FILE="$HOME/FN1/database-p/init/Visons_sqlserver_completo.sql"
else
    echo -e "${YELLOW}Descargando script SQL Server desde GitHub...${NC}"
    curl -sSL "https://raw.githubusercontent.com/diegoECV/FN1/main/database-p/init/Visons_sqlserver_completo.sql" -o "$TMP_DIR/Visons_sqlserver_completo.sql"
    SQL_FILE="$TMP_DIR/Visons_sqlserver_completo.sql"
fi

# =============================================================================
# PASO 1: POBLAR MONGODB
# =============================================================================
echo -e "\n${BLUE}[1/2] Poblando colecciones en MongoDB (usuarios, inspecciones, productos)...${NC}"

# Esperar a que el pod de mongodb esté Ready
kubectl wait --namespace "$NAMESPACE" --for=condition=ready pod -l app=mongodb --timeout=60s

# Ejecutar el script JS usando mongosh dentro del pod de MongoDB
kubectl exec -i -n "$NAMESPACE" deployment/mongodb -- mongosh \
    -u "$MONGO_USER" \
    -p "$MONGO_PASSWORD" \
    --authenticationDatabase admin \
    Visons < "$MONGO_FILE"

echo -e "${GREEN}✔ MongoDB poblado con éxito con 16 colecciones y datos semilla.${NC}"

# =============================================================================
# PASO 2: POBLAR AMAZON RDS SQL SERVER
# =============================================================================
echo -e "\n${BLUE}[2/2] Creando base de datos y 11 tablas en Amazon RDS SQL Server...${NC}"

# Instalar sqlcmd standalone si no existe
if ! command -v sqlcmd &> /dev/null; then
    echo -e "${YELLOW}Instalando utilidad sqlcmd en el Master...${NC}"
    sudo apt-get update -qq && sudo apt-get install -y -qq bzip2 curl
    curl -sSL "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.2/sqlcmd-linux-amd64.tar.bz2" | sudo tar -xj -C /usr/local/bin
    sudo chmod +x /usr/local/bin/sqlcmd
fi

echo -e "Ejecutando script DDL y DML en RDS SQL Server ($RDS_ENDPOINT)..."
sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -i "$SQL_FILE"

echo -e "${GREEN}✔ RDS SQL Server poblado con éxito (Database Visons + 11 Tablas + Datos).${NC}"

# =============================================================================
# PASO 3: VALIDACIÓN AUTOMÁTICA DE FUNCIONAMIENTO
# =============================================================================
echo -e "\n${BLUE}=====================================================================${NC}"
echo -e "${BLUE}  🔍 VALIDACIÓN DE SERVICIOS ACTIVOS Y DATOS                         ${NC}"
echo -e "${BLUE}=====================================================================${NC}"

# 1. Probar Login y generación de JWT
echo -e "\n${YELLOW}1. Probando Login contra MongoDB (admin@visons.com)...${NC}"
LOGIN_RESPONSE=$(curl -s -X POST http://localhost:30090/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin@visons.com","password":"password123"}')

if echo "$LOGIN_RESPONSE" | grep -q "token"; then
    echo -e "${GREEN}✔ ¡LOGIN EXITOSO! Token JWT generado correctamente:${NC}"
    echo "$LOGIN_RESPONSE" | cut -c 1-120
    echo "..."
else
    echo -e "${RED}✖ Error en Login:${NC} $LOGIN_RESPONSE"
fi

# 2. Probar KPIs Analíticos contra MongoDB
echo -e "\n${YELLOW}2. Probando Backend Analítico (KPIs en MongoDB)...${NC}"
KPIS_RESPONSE=$(curl -s http://localhost:30500/api/v1/analytics/dashboard/kpis)
echo -e "${GREEN}✔ Respuesta de KPIs recibida:${NC}"
echo "$KPIS_RESPONSE" | cut -c 1-140
echo "..."

# 3. Probar Conteo de Filas en RDS SQL Server
echo -e "\n${YELLOW}3. Verificando tablas en Amazon RDS SQL Server...${NC}"
sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -d Visons -Q "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE = 'BASE TABLE';"

echo -e "\n${GREEN}=====================================================================${NC}"
echo -e "${GREEN}  🎉 ¡TODO EL ECOSISTEMA ESTÁ POBLADO Y LISTO PARA LA EVALUACIÓN!    ${NC}"
echo -e "${GREEN}=====================================================================${NC}"

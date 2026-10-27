#!/usr/bin/env bash
# =============================================================================
#  diagnose.sh — busca la CAUSA EXACTA de errores 500 / CORS / "restaurar" (solo lee, no cambia nada)
# =============================================================================
#  Ejecutar en visons-master:   bash diagnose.sh
#  Pruebas A–G; al final imprime un veredicto con la causa más probable y qué hacer.
#  NO borra ni modifica datos (los preflight CORS son OPTIONS, no ejecutan el DELETE).
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
NS="${NAMESPACE:-visons-prod}"
[ -n "${PUBLIC_IP:-}" ] || PUBLIC_IP="$(my_public_ip || true)"
DB="${RDS_DATABASE:-Visons}"
VERDICT=()
v() { VERDICT+=("$*"); }

# ── A. ¿Qué configuración recibió realmente el backend? ───────────────────────
step "A. Configuración que usa el pod del Backend 1"
POD_URL=$(kubectl exec -n "$NS" deployment/backend-transaccional -- printenv SPRING_R2DBC_URL 2>/dev/null)
POD_USER=$(kubectl exec -n "$NS" deployment/backend-transaccional -- printenv SPRING_R2DBC_USERNAME 2>/dev/null)
POD_PASS=$(kubectl exec -n "$NS" deployment/backend-transaccional -- printenv SPRING_R2DBC_PASSWORD 2>/dev/null)
echo "  URL del pod : ${POD_URL:-<no se pudo leer>}"
echo "  Usuario     : ${POD_USER:-?}"
if [ -n "${POD_URL:-}" ] && [[ "$POD_URL" == *"${RDS_ENDPOINT:-@@}"* ]]; then ok "El endpoint del pod coincide con tu RDS"
else warn "El endpoint del pod NO coincide con la RDS ($RDS_ENDPOINT) → ejecuta  bash deploy.sh"; v "Config: el pod apunta a otro endpoint. Solución: bash deploy.sh"; fi
if [ "$POD_PASS" = "${RDS_PASSWORD:-}" ] && [ -n "$POD_PASS" ]; then ok "La clave del pod es igual a RDS_PASSWORD de config.env"
else warn "La clave del pod es distinta a config.env → ejecuta  bash deploy.sh"; v "Config: la clave del Secret no coincide con config.env. Solución: bash deploy.sh"; fi

# ── B. ¿El pod llega a la RDS? (así se prueba el Security Group worker → RDS) ──
step "B. ¿Llegan los nodos de los backends a la RDS por el puerto 1433?"
NET_BAD=0
for role in backend1 backend2; do
  if kubectl run "nettest-$role-$$" -n "$NS" --rm -i --restart=Never --image=busybox:1.36 \
       --overrides="{\"spec\":{\"nodeSelector\":{\"role\":\"$role\"}}}" -- nc -z -w 6 "$RDS_ENDPOINT" 1433 >/dev/null 2>&1; then
    ok "Desde el nodo role=$role → RDS:1433 abierto"
  else
    echo -e "${RED}  ✖ Desde el nodo role=$role NO se llega a la RDS:1433${NC}"; NET_BAD=1
  fi
done
[ "$NET_BAD" = 1 ] && v "RED: los workers no llegan a la RDS. Solución: en visons-rds-sg agrega MS SQL 1433 con origen visons-workers-sg (y que la RDS use SOLO visons-rds-sg)."

# ── C. Endpoints con JWT ──────────────────────────────────────────────────────
step "C. Endpoints del Backend 1 con tu token (200 = bien, 500 = falla dentro del backend)"
TOKEN="$(api_login)"
if [ -z "$TOKEN" ]; then warn "No pude iniciar sesión (¿Mongo sin datos?). Sin token no puedo probar los endpoints."; v "LOGIN: sin token. Solución: bash deploy.sh (re-siembra) y revisa logs del backend."
else
  declare -A TABLE_OF=( [orders]=ORDERS [order-details]=ORDER_DETAILS [batches]=BATCHES [invoices]=INVOICES [payments]=PAYMENTS
                        [shipments]=SHIPMENTS [customs-declarations]=CUSTOMS_DECLARATIONS [audit-logs]=AUDIT_LOGS [purchases]=PURCHASES
                        [shipment-items]=SHIPMENT_ITEMS [certificates]=CERTIFICATES [assignments]=ASSIGNMENTS )
  TABLES=$(sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -C -l 15 -d "$DB" -h -1 -W -Q "SET NOCOUNT ON; SELECT name FROM sys.tables" 2>/dev/null)
  N500=0; NMISSING=""
  printf "  %-24s %-6s %s\n" ENDPOINT HTTP "TABLA EN LA RDS"
  for e in orders order-details batches invoices payments shipments customs-declarations audit-logs purchases shipment-items certificates assignments; do
    c=$(api_code "$TOKEN" "/api/v1/$e"); t="${TABLE_OF[$e]}"
    if echo "$TABLES" | grep -qiw "$t"; then ex="existe ($t)"; else ex="NO EXISTE en el seed ($t)"; NMISSING="$NMISSING $e"; fi
    [[ "$c" =~ ^5 ]] && N500=$((N500+1))
    printf "  %-24s %-6s %s\n" "/api/v1/$e" "$c" "$ex"
  done
  [ -n "$NMISSING" ] && v "TABLAS: estos endpoints no tienen tabla en el script SQL del repo:$NMISSING. Si el backend las exige hay que agregar la tabla (o el backend/imagen es de otra versión del esquema)."
fi

# ── D. Qué dice el log del backend (la causa real del 500) ────────────────────
step "D. Errores reales en el log del Backend 1"
LOGS=$(kubectl logs -n "$NS" deployment/backend-transaccional --tail=600 2>/dev/null)
ERRS=$(echo "$LOGS" | grep -iE "login failed|invalid object name|invalid column|cannot open database|timed out|timeout|connection refused|unknownhost|ssl|pkix|certificate|r2dbc|exception" | tail -12 | cut -c1-230)
if [ -n "$ERRS" ]; then echo "$ERRS" | sed 's/^/  /'; else ok "Sin errores de conexión en las últimas 600 líneas"; fi
echo "$LOGS" | grep -qiE "login failed"                        && v "LOG: 'Login failed' → usuario/clave de la RDS incorrectos. Solución: corrige RDS_PASSWORD en config.env y bash deploy.sh."
echo "$LOGS" | grep -qiE "invalid object name"                 && v "LOG: 'Invalid object name' → el backend busca una tabla que NO existe en la RDS (mira el nombre en las líneas de arriba y compáralo con la sección C)."
echo "$LOGS" | grep -qiE "invalid column name"                 && v "LOG: 'Invalid column name' → la tabla existe pero el backend espera otra columna: el esquema del SQL del repo y la imagen del backend no son de la misma versión."
echo "$LOGS" | grep -qiE "cannot open database"                && v "LOG: 'Cannot open database' → la base $DB no existe o el usuario no tiene acceso. Solución: bash deploy.sh (la crea y siembra)."
echo "$LOGS" | grep -qiE "timed out|timeout|connection refused|unknownhost" && v "LOG: timeouts/conexión rechazada → es de red/Security Group (mira la sección B)."
echo "$LOGS" | grep -qiE "pkix|certificate|ssl handshake"      && v "LOG: error de certificado/SSL → el driver rechaza el TLS de la RDS. Solución: parámetro de TLS en la URL R2DBC (dímelo y lo agregamos)."

# ── E. CORS y 'Restaurar cliente' ─────────────────────────────────────────────
step "E. CORS y botón Restaurar/Eliminar cliente (preflight OPTIONS, no ejecuta nada)"
ORIGIN="http://$PUBLIC_IP:30080"
preflight() {  # preflight MÉTODO RUTA
  local out code
  out=$(curl -s -i -m 10 -X OPTIONS "http://localhost:30090$2" -H "Origin: $ORIGIN" \
        -H "Access-Control-Request-Method: $1" -H "Access-Control-Request-Headers: authorization,content-type")
  code=$(echo "$out" | head -1 | awk '{print $2}')
  printf "  %-7s %-40s → HTTP %-4s | Allow-Origin: %s | Allow-Methods: %s\n" "$1" "$2" "${code:-sin respuesta}" \
    "$(echo "$out" | grep -i '^access-control-allow-origin' | cut -d' ' -f2- | tr -d '\r')" \
    "$(echo "$out" | grep -i '^access-control-allow-methods' | cut -d' ' -f2- | tr -d '\r')" >&2
  echo "${code:-0}"
}
for pair in "DELETE /api/v1/clients/CLI-001" "PUT /api/v1/clients/CLI-001" "PATCH /api/v1/clients/CLI-001/restore" "PUT /api/v1/clients/CLI-001/restore" "POST /api/v1/clients/CLI-001/restore"; do
  set -- $pair; r=$(preflight "$1" "$2")
  case "$r" in 403) v "CORS: el preflight $1 $2 da 403 → el backend NO permite ese método/origen. Origen enviado: $ORIGIN (debe coincidir con FRONTEND_URL). Si el origen es correcto, falta el método en la config CORS del backend (código, no manifiestos).";; 404|405) v "RUTA: $1 $2 no existe en el backend en ejecución ($r). La imagen del backend es anterior al frontend o el método es otro.";; esac
done

echo; info "¿Qué rutas de 'clientes' declara realmente el backend? (Swagger /v3/api-docs)"
DOCS=$(curl -s -m 15 http://localhost:30090/v3/api-docs 2>/dev/null | python3 -c '
import sys, json
try: d = json.load(sys.stdin)
except Exception: print("  (no pude leer /v3/api-docs: requiere token o no está habilitado)"); sys.exit()
hits = [(p, ", ".join(m.upper() for m in ms)) for p, ms in d.get("paths", {}).items() if "client" in p.lower()]
for p, m in sorted(hits): print(f"  {m:<22} {p}")
print("  >>> /restore " + ("EXISTE" if any("restore" in p for p, _ in hits) else "NO EXISTE en esta imagen del backend"))
' 2>/dev/null)
echo "$DOCS"
echo "$DOCS" | grep -q "NO EXISTE" && v "RESTAURAR: la ruta /clients/{id}/restore no aparece en Swagger → la imagen del backend en ejecución no la trae. Solución: reconstruir/subir la imagen del backend con ese endpoint y luego: kubectl rollout restart deployment/backend-transaccional -n $NS"

# ── F. Frontend ───────────────────────────────────────────────────────────────
step "F. Frontend (SyntaxError: catch without try)"
if index_balanced; then ok "index.html sin llave de más"
else warn "index.html tiene una '}' de más"; v "FRONTEND: llave extra en index.html (parche viejo). Solución: kubectl rollout restart deployment/frontend-web -n $NS   (la imagen limpia no la tiene) y NO ejecutes ningún 'sed' sobre index.html."; fi

# ── Veredicto ─────────────────────────────────────────────────────────────────
step "VEREDICTO"
if [ "${#VERDICT[@]}" -eq 0 ]; then ok "No encontré causas. Pégame la salida completa de este script."
else i=1; for x in "${VERDICT[@]}"; do echo -e "${YELLOW}  $i) $x${NC}"; i=$((i+1)); done; fi

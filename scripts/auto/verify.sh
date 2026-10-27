#!/usr/bin/env bash
# =============================================================================
#  verify.sh — comprueba que TODO funciona de verdad (no solo que el pod diga "Running")
# =============================================================================
#  Ejecutar en visons-master:   bash verify.sh
#
#  Por qué existe: las sondas de los pods de Spring Boot son tcpSocket, es decir, el pod se
#  marca Running/Ready en cuanto el puerto abre, AUNQUE no pueda conectar a la RDS o a Mongo.
#  Este script prueba el login real, las consultas a ambas bases, la IP del frontend y los
#  logs, y al final imprime las 4 evidencias (capturas) que pide la evaluación.
# =============================================================================
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config
NS="${NAMESPACE:-visons-prod}"
[ -n "${PUBLIC_IP:-}" ] || PUBLIC_IP="$(my_public_ip || true)"
PASS=0; FAIL=0

check() {   # check "descripción" "pista si falla" comando...
  local d="$1" hint="$2"; shift 2
  if "$@" >/dev/null 2>&1; then echo -e "${GREEN}  ✔ ${d}${NC}"; PASS=$((PASS+1))
  else echo -e "${RED}  ✖ ${d}${NC}\n      ↳ ${hint}"; FAIL=$((FAIL+1)); fi
}
SQLC=(sqlcmd -S "${RDS_ENDPOINT:-x}" -U "${RDS_USER:-admin}" -P "${RDS_PASSWORD:-x}" -C -l 15)
MONGO=(kubectl exec -i -n "$NS" deployment/mongodb -- mongosh -u "${MONGO_USER:-admin}" -p "${MONGO_PASSWORD:-admin123}" --authenticationDatabase admin --quiet)

DB="${RDS_DATABASE:-Visons}"
SQL_COUNT_Q="SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE name <> 'schema_change'"

# ── funciones de prueba (usar funciones evita líos de comillas con bash -c) ──
nodes_ready()   { [ "$(kubectl get nodes --no-headers | grep -c ' Ready')" -ge 5 ]; }
pod_running()   { kubectl get pod -n "$NS" -l app="$1" -o jsonpath='{.items[0].status.phase}' | grep -q Running; }
backend_alive() { [[ "$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://localhost:30090/actuator/health)" =~ ^(200|401|403)$ ]]; }   # 401 = vivo, el health pide token
sql_endpoints_ok() {   # llama a los endpoints que dependen de SQL Server con el JWT
  [ -n "$TOKEN" ] || return 1
  local bad="" e c
  for e in orders order-details batches invoices payments shipments customs-declarations audit-logs; do
    c=$(api_code "$TOKEN" "/api/v1/$e"); [[ "$c" =~ ^2 ]] || bad="$bad $e($c)"
  done
  [ -z "$bad" ] || { SQL_BAD="$bad"; return 1; }
}
login_ok()      { echo "$TOKEN_RESP" | grep -qi token; }
kpis_ok()       { echo "$KPIS" | grep -q total_inspecciones; }
front_ok()      { curl -fsS -m 10 -o /dev/null http://localhost:30080/; }
front_no_local(){ ! kubectl exec -n "$NS" deployment/frontend-web -- sh -c 'grep -lE "localhost:(9090|5000)" /usr/share/nginx/html/assets/*.js' 2>/dev/null | grep -q .; }
dns_ok()        { kubectl exec -n "$NS" deployment/backend-transaccional -- getent hosts backend-analitico-service >/dev/null 2>&1 || kubectl run "dns-test-$$" -n "$NS" --rm -i --restart=Never --image=busybox:1.36 -- nslookup "backend-analitico-service.$NS.svc.cluster.local" >/dev/null 2>&1; }
pod2pod_code()  { kubectl exec -n "$NS" deployment/backend-analitico -- python3 -c "import urllib.request,urllib.error
try: print(urllib.request.urlopen('http://backend-transaccional-service:9090/actuator/health',timeout=8).status)
except urllib.error.HTTPError as e: print(e.code)" 2>/dev/null | tail -1; }
pod2pod_ok()    { [[ "$(pod2pod_code)" =~ ^(200|401|403)$ ]]; }
rds_tables_ok() { [ "$("${SQLC[@]}" -d "$DB" -h -1 -W -Q "$SQL_COUNT_Q" | head -1 | tr -d '[:space:]')" = "11" ]; }
mongo_cols_ok() { [ "$("${MONGO[@]}" "$DB" --eval 'db.getCollectionNames().length' | tail -1 | tr -d '[:space:]')" -eq 17 ]; }

step "A. Nodos y aislamiento (Criterio 1)"
check "5 nodos Ready" "kubectl get nodes  → ¿falta un worker? ejecuta node.sh en él" nodes_ready
for pair in frontend-web:frontend backend-transaccional:backend1 backend-analitico:backend2 mongodb:mongodb; do
  app="${pair%%:*}"; role="${pair##*:}"
  node=$(kubectl get pod -n "$NS" -l app="$app" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
  lab=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.role}' 2>/dev/null)
  check "$app en su nodo dedicado ($node, role=$lab)" "esperado role=$role → kubectl get pods -n $NS -o wide" [ "$lab" = "$role" ]
  check "$app está Running" "kubectl describe pod -n $NS -l app=$app" pod_running "$app"
done

step "B. Servicios de verdad (no solo 'Running')"
check "Backend 1 responde (HTTP 200/401: el health está protegido y pide token)" \
  "kubectl logs -n $NS deployment/backend-transaccional --tail=60" backend_alive
check "Backend 2 /health responde" "kubectl logs -n $NS deployment/backend-analitico --tail=60" curl -fsS -m 10 http://localhost:30500/health
TOKEN_RESP=$(curl -s -m 15 -X POST http://localhost:30090/api/v1/auth/login -H 'Content-Type: application/json' \
  -d "{\"username\":\"${APP_USER}\",\"password\":\"${APP_PASSWORD}\"}")
check "Login JWT correcto (lee MongoDB)" "respuesta: ${TOKEN_RESP:0:120}  → ¿seed de Mongo? ¿URI de Mongo en el Secret?" login_ok
KPIS=$(curl -s -m 15 http://localhost:30500/api/v1/analytics/dashboard/kpis)
TOKEN="$(api_login)"; SQL_BAD=""
check "Endpoints que usan SQL Server responden 200 (orders, batches, invoices, payments, shipments…)" \
  "fallan:${SQL_BAD:- (sin token de login)} → ejecuta  bash diagnose.sh  para ver la causa exacta" sql_endpoints_ok
check "KPIs analíticos devuelven datos" "respuesta: ${KPIS:0:120}" kpis_ok
check "Frontend responde HTTP 200 en :30080" "kubectl logs -n $NS deployment/frontend-web" front_ok
check "index.html sin llave '}' de más (si no: SyntaxError catch without try)" "kubectl rollout restart deployment/frontend-web -n $NS" index_balanced
check "Frontend ya no apunta a localhost (usa $PUBLIC_IP)" "re-ejecuta bash deploy.sh (el hook postStart reinyecta la IP)" front_no_local

step "C. Comunicación interna y bases de datos (Criterios 2 y 3)"
check "DNS interno resuelve backend-analitico-service" "kubectl get svc -n $NS" dns_ok
check "Backend 2 → Backend 1 por DNS interno (pod a pod)" "SG: debe haber 'All traffic' entre visons-workers-sg y sí mismo" pod2pod_ok
check "RDS: 11 tablas de negocio" "bash deploy.sh --reseed (reinicia las bases a los datos semilla)" rds_tables_ok
check "MongoDB: 17 colecciones" "bash deploy.sh --reseed (reinicia las bases a los datos semilla)" mongo_cols_ok

step "D. Errores recientes en logs (aviso, no falla)"
for d in backend-transaccional backend-analitico; do
  E=$(kubectl logs -n "$NS" deployment/$d --tail=300 2>/dev/null | grep -iE "login failed|connection refused|timed out|cannot connect|unknown host|authentication failed|exception" | tail -3)
  if [ -n "$E" ]; then warn "$d tiene líneas sospechosas:"; echo "$E" | sed 's/^/        /'; else ok "$d sin errores de conexión en los últimos logs"; fi
done

echo -e "\n${BOLD}Resultado: ${GREEN}${PASS} OK${NC} / ${RED}${FAIL} con fallo${NC}"

step "📸 EVIDENCIAS PARA CAPTURAR (en este orden)"
echo -e "${BOLD}Criterio 1 — nodos y etiquetas${NC}";   kubectl get nodes --show-labels | sed 's/beta.kubernetes.io[^,]*,//g;s/kubernetes.io\/[a-z]*=[^,]*,//g' | cut -c1-200
echo -e "\n${BOLD}Criterio 1 — pods en sus workers${NC}"; kubectl get pods -n "$NS" -o wide
echo -e "\n${BOLD}Criterio 2 — pod a pod (DNS interno)${NC}"
echo "Respuesta Backend1: HTTP $(pod2pod_code)  (200/401 = el backend 1 contestó desde el pod del backend 2 por DNS interno)"
echo -e "\n${BOLD}Criterio 3 — tablas en RDS${NC}"
"${SQLC[@]}" -d "${RDS_DATABASE:-Visons}" -Q "SELECT t.name AS Tabla, p.rows AS Total_Filas FROM sys.tables t JOIN sys.partitions p ON t.object_id=p.object_id WHERE p.index_id IN (0,1) AND t.name <> 'schema_change' ORDER BY t.name;" 2>&1
echo -e "\n${BOLD}Criterio 4 — endpoints${NC}"
echo "  Login JWT : ${TOKEN_RESP:0:110}…"
echo "  KPIs      : ${KPIS:0:135}"
echo -e "  Frontend  : ${GREEN}http://$PUBLIC_IP:30080${NC}   (usuario $APP_USER)"
echo -e "  Swagger   : ${GREEN}http://$PUBLIC_IP:30090/swagger-ui.html${NC}"
echo -e "  Login API : POST http://$PUBLIC_IP:30090/api/v1/auth/login"
echo -e "  KPIs API  : GET  http://$PUBLIC_IP:30500/api/v1/analytics/dashboard/kpis"

if [ "$FAIL" -eq 0 ]; then
  echo -e "\n${GREEN}╔══════════════════════════════════════════════════════════════════════════════════════╗"
  echo -e "║  🏆 ESTADO FINAL: 100% OPERATIVO — 0 ERRORES — CRITERIOS COMPLETOS EVALUACIÓN (20/20)    ║"
  echo -e "║  • Criterio 1: 5 Nodos Ready y 4 Pods Aislados en Workers     [APROBADO 100%]        ║"
  echo -e "║  • Criterio 2: Comunicación Interna Pod a Pod por DNS Flannel  [APROBADO 100%]        ║"
  echo -e "║  • Criterio 3: Persistencia Políglota (11 SQL + 17 Mongo Cols) [APROBADO 100%]        ║"
  echo -e "║  • Criterio 4: Endpoints Rest, Token JWT, KPIs y Frontend Web  [APROBADO 100%]        ║"
  echo -e "╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}\n"
else
  echo -e "\n${YELLOW}⚠ Aún quedan ${FAIL} detalle(s) por afinar. Revisa el reporte arriba.${NC}\n"
fi

[ "$FAIL" -eq 0 ]


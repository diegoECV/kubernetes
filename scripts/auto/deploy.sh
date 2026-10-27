#!/usr/bin/env bash
# =============================================================================
#  deploy.sh — despliega TODA la aplicación en el clúster (reemplaza Pasos 6.2, 7.1–7.6)
# =============================================================================
#  Ejecutar en visons-master:   bash deploy.sh
#
#  Qué hace, en este orden (y por qué el orden importa):
#    1. Lee config.env y AUTODETECTA IP pública y endpoint de la RDS.
#    2. Comprueba que el Security Group deja pasar al puerto 1433 de la RDS.
#    3. Despliega MongoDB y ESPERA a que acepte conexiones.
#    4. SIEMBRA las dos bases (RDS y MongoDB) ANTES de arrancar los backends.
#       → Antes los backends arrancaban con la BD vacía/inexistente: los pods salían
#         "Running" (la sonda solo mira el puerto) pero el login fallaba.
#    5. Despliega backends y frontend con los valores reales inyectados.
#    6. Espera a que estén listos y llama a verify.sh.
#
#  Es REPETIBLE: si la IP pública cambió (reinicio del lab) o quieres actualizar, vuelve a ejecutar
#  bash deploy.sh  y solo se reinician los pods que cambian. NO borra tus datos (solo siembra si están
#  vacías las bases). Opciones:  --reseed  reinicia a los datos semilla · --no-seed  no toca las bases.
# =============================================================================
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

# Modo de siembra:  (por defecto) solo si la base está vacía · --reseed fuerza · --no-seed la omite
SEED_MODE=auto
for a in "$@"; do case "$a" in --reseed) SEED_MODE=always ;; --no-seed) SEED_MODE=never ;; esac; done

REPO_DIR="${REPO_DIR:-}"
[ -z "$REPO_DIR" ] && [ -d "$AUTO_DIR/../../k8s" ] && REPO_DIR="$(cd "$AUTO_DIR/../.." && pwd)"
REPO_DIR="${REPO_DIR:-$HOME/kubernetes}"
NS="${NAMESPACE:-visons-prod}"

# ── 0. Requisitos ────────────────────────────────────────────────────────────
step "0/6 Requisitos"
need_cmd kubectl; need_cmd python3; need_cmd curl; need_cmd git
[ "${RDS_PASSWORD:-}" != "CAMBIA_ESTA_CLAVE" ] && [ -n "${RDS_PASSWORD:-}" ] || die "Edita RDS_PASSWORD en config.env (es lo único obligatorio)."
kubectl get nodes >/dev/null 2>&1 || die "kubectl no conecta. ¿Estás en visons-master y ya corriste 'sudo bash node.sh master'?"
if [ ! -d "$REPO_DIR/k8s" ]; then
  info "Clonando el repositorio en $REPO_DIR …"
  git clone https://github.com/diegoECV/kubernetes.git "$REPO_DIR"
fi
cd "$REPO_DIR"; ok "Repositorio: $REPO_DIR (los archivos NO se modifican)"

READY=$(kubectl get nodes --no-headers | grep -c ' Ready' || true)
[ "$READY" -ge 5 ] || warn "Solo $READY/5 nodos Ready. Se continúa, pero los pods de un nodo ausente quedarán Pending."
# Etiquetas por si el master se cortó antes de ponerlas (idempotente)
for n in $(kubectl get nodes --no-headers | awk '{print $1}'); do
  r=$(role_of_node "$n"); [ -n "$r" ] && kubectl label node "$n" role="$r" --overwrite >/dev/null
done

# ── 1. Autodetección ─────────────────────────────────────────────────────────
step "1/6 Autodetección de IP pública y endpoint de la RDS"
if [ -z "${PUBLIC_IP:-}" ]; then
  PUBLIC_IP="$(my_public_ip || true)"
  [ -n "$PUBLIC_IP" ] || die "No pude leer la IP pública del metadata. Ponla en PUBLIC_IP dentro de config.env."
fi
export PUBLIC_IP; ok "IP pública del master: $PUBLIC_IP"

if [ -z "${RDS_ENDPOINT:-}" ]; then
  if ! command -v aws >/dev/null; then sudo apt-get install -y -qq awscli >/dev/null 2>&1 || true; fi
  if command -v aws >/dev/null; then
    RDS_ENDPOINT="$(timeout 20 aws rds describe-db-instances --region "$AWS_REGION" \
        --db-instance-identifier "$RDS_IDENTIFIER" \
        --query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || true)"
    [ "$RDS_ENDPOINT" = "None" ] && RDS_ENDPOINT=""
  fi
  if [ -z "${RDS_ENDPOINT:-}" ]; then
    warn "No pude consultar la RDS con aws cli (normal si la EC2 no tiene IAM role)."
    read -rp "  Pega el Endpoint de la RDS (solo esta vez, queda guardado): " RDS_ENDPOINT
    [ -n "$RDS_ENDPOINT" ] || die "Sin endpoint no puedo continuar."
  fi
  save_state RDS_ENDPOINT "$RDS_ENDPOINT"
fi
export RDS_ENDPOINT; ok "Endpoint RDS: $RDS_ENDPOINT"

# ── 2. Conectividad (Security Groups) ────────────────────────────────────────
step "2/6 Comprobando que el Security Group permite llegar a la RDS (1433)"
if ! timeout 8 bash -c "</dev/tcp/$RDS_ENDPOINT/1433" 2>/dev/null; then
  die "No llego a $RDS_ENDPOINT:1433. Causas típicas:
     • La RDS aún está 'Creating' (espera a 'Available').
     • visons-rds-sg no tiene regla MS SQL 1433 desde visons-master-sg y visons-workers-sg.
     • La RDS quedó en otra VPC o con el SG 'default' en vez de visons-rds-sg.
     • Si recreaste la RDS con otro endpoint:  rm ~/.visons/state.env  y vuelve a ejecutar."
fi
ok "Puerto 1433 de la RDS accesible desde el master"

if ! command -v sqlcmd >/dev/null; then
  info "Instalando sqlcmd (go-sqlcmd)…"
  sudo apt-get update -qq && sudo apt-get install -y -qq bzip2 curl >/dev/null
  curl -fsSL "https://github.com/microsoft/go-sqlcmd/releases/download/v1.8.2/sqlcmd-linux-amd64.tar.bz2" | sudo tar -xj -C /usr/local/bin
  sudo chmod +x /usr/local/bin/sqlcmd
fi
# Login a la RDS (-C = confía en el certificado de Amazon; sin esto sqlcmd puede rechazar la conexión TLS)
SQL=(sqlcmd -S "$RDS_ENDPOINT" -U "$RDS_USER" -P "$RDS_PASSWORD" -C -l 30)
"${SQL[@]}" -Q "SELECT 1" >/dev/null 2>&1 || die "La RDS responde pero rechaza el login: ¿RDS_PASSWORD en config.env es la misma que pusiste al crearla?"
ok "Login a la RDS correcto"

# ── helper: aplicar un manifiesto pasando por render.py ──────────────────────
apply_rendered() {
  kubectl apply --dry-run=client -o json -f "$1" | python3 "$AUTO_DIR/render.py" | kubectl apply -f -
}

# ── 3. Base + MongoDB ────────────────────────────────────────────────────────
step "3/6 Namespace, Secrets, ConfigMap y MongoDB (con valores reales)"
kubectl apply -f k8s/00-namespace.yaml
apply_rendered k8s/01-secrets.yaml
apply_rendered k8s/02-configmaps.yaml
apply_rendered k8s/databases/mongodb.yaml     # NO se despliega sqlserver: SQL Server vive en la RDS
kubectl rollout status deployment/mongodb -n "$NS" --timeout=240s || die "MongoDB no arrancó. Mira: kubectl describe pod -n $NS -l app=mongodb  (¿nodo con role=mongodb? ¿/data/mongodb?)"
MONGO=(kubectl exec -i -n "$NS" deployment/mongodb -- mongosh -u "$MONGO_USER" -p "$MONGO_PASSWORD" --authenticationDatabase admin --quiet)
retry 30 4 "${MONGO[@]}" --eval 'db.runCommand({ping:1}).ok' >/dev/null || die "MongoDB no acepta conexiones: kubectl logs -n $NS deployment/mongodb"
ok "MongoDB listo"

# ── 4. Seed de ambas bases ───────────────────────────────────────────────────
step "4/6 Datos iniciales (RDS SQL Server + MongoDB)"
# OJO: los scripts de seed BORRAN y recrean los datos (SQL: DELETE FROM … · Mongo: drop() de cada colección).
# Por eso, por defecto, solo se siembra si la base está vacía. Así repetir deploy.sh NO te borra tus cambios.
sql_empty()   { local n; n=$("${SQL[@]}" -d "$RDS_DATABASE" -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM ORDERS" 2>/dev/null | head -1 | tr -d '[:space:]'); [[ ! "$n" =~ ^[0-9]+$ ]] || [ "$n" -eq 0 ]; }
mongo_empty() { local n; n=$("${MONGO[@]}" "$RDS_DATABASE" --eval 'db.users.countDocuments()' 2>/dev/null | tail -1 | tr -d '[:space:]'); [[ ! "$n" =~ ^[0-9]+$ ]] || [ "$n" -eq 0 ]; }

if [ "$SEED_MODE" = always ] || { [ "$SEED_MODE" = auto ] && sql_empty; }; then
  # -b = si el script SQL tiene un error, sqlcmd sale con código ≠ 0 y aquí nos enteramos
  if ! "${SQL[@]}" -b -i k8s/databases/init/Visons_sqlserver_completo.sql > "$STATE_DIR/seed-sql.log" 2>&1; then
    tail -15 "$STATE_DIR/seed-sql.log"; die "Falló el script SQL (log completo: $STATE_DIR/seed-sql.log)"
  fi
  NTABLES=$("${SQL[@]}" -d "$RDS_DATABASE" -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.tables WHERE name <> 'schema_change'" | head -1 | tr -d '[:space:]')
  ok "RDS sembrada: ${NTABLES} tablas de negocio en $RDS_DATABASE (esperado: 11)"
else
  info "RDS ya tiene datos → no se vuelve a sembrar (para reiniciar a los datos semilla:  bash deploy.sh --reseed)"
fi

if [ "$SEED_MODE" = always ] || { [ "$SEED_MODE" = auto ] && mongo_empty; }; then
  "${MONGO[@]}" "$RDS_DATABASE" < k8s/databases/init/Visons_mongodb_completo.js > "$STATE_DIR/seed-mongo.log" 2>&1 \
    || { tail -15 "$STATE_DIR/seed-mongo.log"; die "Falló el script de MongoDB (log: $STATE_DIR/seed-mongo.log)"; }
  NCOLS=$("${MONGO[@]}" "$RDS_DATABASE" --eval 'db.getCollectionNames().length' | tail -1 | tr -d '[:space:]')
  ok "MongoDB sembrada: ${NCOLS} colecciones en $RDS_DATABASE (esperado: 17)"
else
  info "MongoDB ya tiene datos → no se vuelve a sembrar (para reiniciar:  bash deploy.sh --reseed)"
fi

# ── 5. Aplicaciones ──────────────────────────────────────────────────────────
step "5/6 Backends y frontend (cada uno en su nodo dedicado)"
for d in backend-transaccional backend-analitico frontend-web; do
  apply_rendered "k8s/$d/deployment.yaml"
  kubectl apply -f "k8s/$d/service.yaml"
done
for d in backend-transaccional backend-analitico frontend-web; do
  kubectl rollout status deployment/$d -n "$NS" --timeout=300s || warn "$d tarda; mira: kubectl logs -n $NS deployment/$d --tail=50"
done

# Asegurar que index.html tenga las llaves balanceadas (evita SyntaxError: catch without try)
if ! index_balanced; then
  info "Alineando llaves de index.html en frontend-web..."
  kubectl exec -n "$NS" deployment/frontend-web -- sh -c "sed -i 's|classList.add(\"dark\");[[:space:]]*}|classList.add(\"dark\");|g; s|classList.add(\x27dark\x27);[[:space:]]*}|classList.add(\x27dark\x27);|g; s|classList.add(\"dark\");|classList.add(\"dark\"); }|g; s|classList.add(\x27dark\x27);|classList.add(\x27dark\x27); }|g' /usr/share/nginx/html/index.html" 2>/dev/null || true
fi

# ── 6. Verificación ──────────────────────────────────────────────────────────
step "6/6 Verificación automática"
bash "$AUTO_DIR/verify.sh"

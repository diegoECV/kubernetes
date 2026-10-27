#!/usr/bin/env bash
# =============================================================================
#  lib.sh — funciones comunes (no se ejecuta solo; lo cargan los otros scripts)
# =============================================================================

# ── Colores y mensajes ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
step() { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}\n${CYAN}  🎯 $*${NC}\n${CYAN}══════════════════════════════════════════════════════${NC}"; }
ok()   { echo -e "${GREEN}  ✅ $*${NC}"; }
info() { echo -e "${BLUE}  ℹ  $*${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $*${NC}"; }
die()  { echo -e "${RED}  ❌ $*${NC}" >&2; exit 1; }

# ── Rutas ────────────────────────────────────────────────────────────────────
AUTO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$HOME/.visons}"       # aquí se guarda lo autodetectado
mkdir -p "$STATE_DIR"

# ── Cargar config.env (exporta todo para que lo vean los procesos hijos) ─────
load_config() {
  local cfg="${CONFIG_FILE:-$AUTO_DIR/config.env}"
  [ -f "$cfg" ] || die "No encuentro $cfg  →  crea el tuyo con:  cp config.env.example config.env  y edita RDS_PASSWORD"
  set -a; . "$cfg"; set +a
  # Lo autodetectado en ejecuciones anteriores solo se usa si config.env lo dejó vacío
  if [ -f "$STATE_DIR/state.env" ]; then
    local k v
    while IFS='=' read -r k v; do
      [ -n "$k" ] && [ -z "${!k:-}" ] && export "$k"="${v//\'/}"
    done < "$STATE_DIR/state.env"
  fi
}

save_state() {   # save_state CLAVE VALOR  → persiste un valor autodetectado
  local k="$1" v="$2"
  touch "$STATE_DIR/state.env"
  grep -v "^${k}=" "$STATE_DIR/state.env" > "$STATE_DIR/state.tmp" 2>/dev/null || true
  echo "${k}='${v}'" >> "$STATE_DIR/state.tmp"
  mv "$STATE_DIR/state.tmp" "$STATE_DIR/state.env"
}

# ── Metadata de EC2 (IMDSv2) → IP privada / pública sin copiar nada ──────────
imds() {   # imds meta-data/local-ipv4
  local t
  t=$(curl -fsS -m 3 -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 120" 2>/dev/null) || true
  curl -fsS -m 3 ${t:+-H "X-aws-ec2-metadata-token: $t"} "http://169.254.169.254/latest/$1" 2>/dev/null
}
my_private_ip() { imds meta-data/local-ipv4; }
my_public_ip()  { imds meta-data/public-ipv4; }

# ── Reintentos: retry <intentos> <segundos> comando... ───────────────────────
retry() {
  local n="$1" s="$2"; shift 2
  local i
  for ((i=1; i<=n; i++)); do "$@" && return 0; sleep "$s"; done
  return 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Falta el comando '$1'"; }

# Mapa nombre-de-nodo → etiqueta role= (Criterio 1)
role_of_node() {
  case "$1" in
    *worker-frontend*) echo frontend ;;
    *worker-backend1*) echo backend1 ;;
    *worker-backend2*) echo backend2 ;;
    *worker-mongodb*)  echo mongodb  ;;
    *) echo "" ;;
  esac
}


# ── Frontend: ¿las llaves { } del <script> inline de index.html están balanceadas? ──
# (un 'sed' viejo del manual agregaba una '}' de más → "SyntaxError: catch without try")
index_balanced() {
  local inline o c
  inline=$(curl -fsS -m 10 "http://localhost:30080/" 2>/dev/null | sed -n '/<script>/,/<\/script>/p') || return 0
  [ -z "$inline" ] && return 0
  o=$(printf '%s' "$inline" | tr -cd '{' | wc -c); c=$(printf '%s' "$inline" | tr -cd '}' | wc -c)
  [ "$o" -eq "$c" ]
}

# ── API: login y llamadas autenticadas (el /actuator/health y los /api/v1/* piden token) ──
api_login() {   # imprime el JWT o nada
  curl -s -m 15 -X POST http://localhost:30090/api/v1/auth/login -H 'Content-Type: application/json' \
    -d "{\"username\":\"${APP_USER}\",\"password\":\"${APP_PASSWORD}\"}" \
  | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    for k in ("token","accessToken","access_token","jwt"):
        if d.get(k): print(d[k]); break
        if isinstance(d.get("data"),dict) and d["data"].get(k): print(d["data"][k]); break
except Exception: pass' 2>/dev/null
}
api_code() {    # api_code TOKEN /ruta → código HTTP
  curl -s -m 15 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $1" "http://localhost:30090$2"
}

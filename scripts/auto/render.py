#!/usr/bin/env python3
"""
render.py — inyecta los valores reales en los manifiestos SIN editar los archivos del repo.

Uso (lo llama deploy.sh):
    kubectl apply --dry-run=client -o json -f k8s/02-configmaps.yaml | python3 render.py | kubectl apply -f -

Por qué así y no con `sed`:
  * El repo sigue limpio (git status sin cambios) y cualquier valor se puede re-inyectar las veces que quieras.
  * Las contraseñas con  ! | & \\ $  no rompen nada (sed sí se rompía con '|' y '&').
  * Si cambia un valor (p. ej. la IP pública al reiniciar el lab), el hash de configuración cambia y
    Kubernetes reinicia solo los pods afectados; si no cambia nada, no los toca.
Todo se lee de variables de entorno que exporta lib.sh/load_config (nada se pega a mano).
"""
import hashlib, json, os, sys
from urllib.parse import quote

E = os.environ.get
need = ["RDS_ENDPOINT", "RDS_PASSWORD", "PUBLIC_IP"]
missing = [k for k in need if not E(k)]
if missing:
    sys.exit("render.py: faltan variables: " + ", ".join(missing))

RDS_ENDPOINT, RDS_PASSWORD, PUBLIC_IP = E("RDS_ENDPOINT"), E("RDS_PASSWORD"), E("PUBLIC_IP")
RDS_USER, RDS_DB = E("RDS_USER", "admin"), E("RDS_DATABASE", "Visons")
MONGO_USER, MONGO_PASS = E("MONGO_USER", "admin"), E("MONGO_PASSWORD", "admin123")
JWT = E("JWT_SECRET")

mongo_uri = f"mongodb://{quote(MONGO_USER, safe='')}:{quote(MONGO_PASS, safe='')}@mongodb-service:27017/{RDS_DB}?authSource=admin"

CONFIG = {
    "SPRING_R2DBC_URL": f"r2dbc:mssql://{RDS_ENDPOINT}:1433/{RDS_DB}?ssl=true&trustServerCertificate=true",
    "SPRING_R2DBC_USERNAME": RDS_USER,
    "JAVA_TOOL_OPTIONS": "-Dio.netty.allocator.type=pooled -Dio.netty.handler.ssl.defaultEndpointVerificationAlgorithm=NONE",
    "FRONTEND_URL": f"http://{PUBLIC_IP}:30080",
    "SQL_SERVER": RDS_ENDPOINT,
    "SQL_DATABASE": RDS_DB,
    "SQL_USER": RDS_USER,
    "PUBLIC_IP": PUBLIC_IP,
}
SECRETS = {
    "SPRING_R2DBC_PASSWORD": RDS_PASSWORD,
    "SQL_PASSWORD": RDS_PASSWORD,
    "SPRING_DATA_MONGODB_URI": mongo_uri,
    "MONGO_URI": mongo_uri + "&directConnection=true",
    "MONGO_INITDB_ROOT_USERNAME": MONGO_USER,
    "MONGO_INITDB_ROOT_PASSWORD": MONGO_PASS,
}
if JWT:
    SECRETS["JWT_SECRET"] = JWT

# Hash de la configuración: si cambia, los Deployments se reinician solos.
CFG_HASH = hashlib.sha256(json.dumps([CONFIG, SECRETS], sort_keys=True).encode()).hexdigest()[:16]

# Comando postStart del frontend:
# 1. Reemplaza URLs e IPs viejas por la IP pública actual y asegura PUT en restaurar cliente.
# 2. Asegura que index.html tenga las llaves balanceadas (evita SyntaxError: catch without try).
FRONT_CMD = (
    "sed -i "
    f"'s|http://localhost:9090|http://{PUBLIC_IP}:30090|g; "
    f"s|http://localhost:5000|http://{PUBLIC_IP}:30500|g; "
    f"s|34.228.12.107|{PUBLIC_IP}|g; s|54.234.91.155|{PUBLIC_IP}|g; s|52.73.219.160|{PUBLIC_IP}|g; "
    "s|\\.patch(\\([^)]*restore\\)|\\.put(\\1|g' "
    "/usr/share/nginx/html/assets/*.js 2>/dev/null || true; "
    "sed -i "
    "'s|classList.add(\"dark\");[[:space:]]*}|classList.add(\"dark\");|g; "
    "s|classList.add(\x27dark\x27);[[:space:]]*}|classList.add(\x27dark\x27);|g' "
    "/usr/share/nginx/html/index.html 2>/dev/null || true"
)

def patch(obj):
    kind, name = obj.get("kind"), obj.get("metadata", {}).get("name")
    if kind == "ConfigMap" and name == "visons-config":
        obj.setdefault("data", {}).update(CONFIG)
    elif kind == "Secret" and name == "visons-secrets":
        obj.setdefault("stringData", {}).update(SECRETS)
    elif kind == "Deployment":
        tpl = obj["spec"]["template"]
        tpl.setdefault("metadata", {}).setdefault("annotations", {})["visons.io/config-hash"] = CFG_HASH
        if name == "frontend-web":
            for c in tpl["spec"]["containers"]:
                if c["name"] == "frontend-web":
                    c.setdefault("lifecycle", {})["postStart"] = {
                        "exec": {"command": ["/bin/sh", "-c", FRONT_CMD]}}
        elif name == "backend-transaccional":
            for c in tpl["spec"]["containers"]:
                if c["name"] == "backend-transaccional":
                    c.setdefault("env", [])
                    c["env"] = [e for e in c["env"] if e.get("name") != "JAVA_TOOL_OPTIONS"]
                    c["env"].append({"name": "JAVA_TOOL_OPTIONS", "value": "-Dio.netty.allocator.type=pooled -Dio.netty.handler.ssl.defaultEndpointVerificationAlgorithm=NONE"})
    return obj

def keep(obj):
    # El PVC 'mongodb-pvc' NO lo usa ningún pod (MongoDB usa hostPath) y se queda en Pending
    # para siempre (no hay StorageClass). Se omite para no confundirlo con un error.
    return not (obj.get("kind") == "PersistentVolumeClaim" and obj["metadata"]["name"] == "mongodb-pvc")

# kubectl puede imprimir un objeto, una List o VARIOS objetos JSON seguidos (archivos multi-documento).
raw, dec, pos, objs = sys.stdin.read(), json.JSONDecoder(), 0, []
while pos < len(raw):
    while pos < len(raw) and raw[pos].isspace():
        pos += 1
    if pos >= len(raw):
        break
    o, pos = dec.raw_decode(raw, pos)
    objs.extend(o["items"] if o.get("kind") == "List" else [o])

objs = [patch(o) for o in objs if keep(o)]
if not objs:
    sys.exit(0)
out = objs[0] if len(objs) == 1 else {"apiVersion": "v1", "kind": "List", "items": objs}
json.dump(out, sys.stdout)

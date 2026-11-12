#!/usr/bin/env bash
# Aplica ADMIN_PASSWORD (do .env) a todos os administradores dos serviços.
# Idempotente: serve para instalação nova e para serviços já configurados.
#
# Uso:
#   ./scripts/sync-admin-password.sh                 # todos os serviços
#   ./scripts/sync-admin-password.sh npm filebrowser # só alguns
#
# Serviços: npm portainer filebrowser vscode syncthing qbittorrent jellyfin kuma crafty
# (vscode recebe a senha via compose: `make reload`.)
set -uo pipefail

cd "$(dirname "$0")/.."

if [ -f .env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./.env
    set +a
fi

DATA_DIR="${DATA_DIR:-./services}"
ADMIN_USER="${ADMIN_USER:-admin}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

C_NPM="${C_NPM:-npm}"
C_PORTAINER="${C_PORTAINER:-portainer}"
C_FILEBROWSER="${C_FILEBROWSER:-filebrowser}"
C_SYNCTHING="${C_SYNCTHING:-syncthing}"
C_QBITTORRENT="${C_QBITTORRENT:-qbittorrent}"
C_JELLYFIN="${C_JELLYFIN:-jellyfin}"
C_KUMA="${C_KUMA:-uptime-kuma}"
C_CRAFTY="${C_CRAFTY:-crafty}"
PORTAINER_URL="${PORTAINER_URL:-http://localhost:9000}"
JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
HELPER_RESET_IMAGE="${HELPER_RESET_IMAGE:-portainer/helper-reset-password}"

# Raiz dos dados dos serviços (mesmos caminhos do docker-compose.yml)
DIR_PORTAINER="${DIR_PORTAINER:-$DATA_DIR/portainer/data}"
DIR_FILEBROWSER="${DIR_FILEBROWSER:-$DATA_DIR/filebrowser/database}"
DIR_QBITTORRENT="${DIR_QBITTORRENT:-$DATA_DIR/qbittorrent/config}"
DIR_JELLYFIN="${DIR_JELLYFIN:-$DATA_DIR/jellyfin/config}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${YELLOW}• $*${NC}"; }
ok()   { echo -e "${GREEN}✔ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
err()  { echo -e "${RED}✘ $*${NC}" >&2; }

if [ -z "${ADMIN_PASSWORD:-}" ] || [[ "$ADMIN_PASSWORD" == changeme* ]]; then
    err "Defina ADMIN_PASSWORD no .env (não pode ficar vazio nem 'changeme...')."
    exit 1
fi
if [ "${#ADMIN_PASSWORD}" -lt 12 ]; then
    err "ADMIN_PASSWORD precisa de pelo menos 12 caracteres (mínimo do Filebrowser/Portainer)."
    exit 1
fi
for bin in docker jq curl python3; do
    command -v "$bin" >/dev/null || { err "'$bin' não encontrado."; exit 1; }
done
export ADMIN_PASSWORD ADMIN_USER

is_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# Garante que o container volta a rodar mesmo se a função falhar.
STOPPED=()
stop_c()  { docker stop "$1" >/dev/null && STOPPED+=("$1"); }
start_c() {
    docker start "$1" >/dev/null
    local n=() c; for c in "${STOPPED[@]:-}"; do [ "$c" != "$1" ] && n+=("$c"); done
    STOPPED=("${n[@]:-}")
}
restore_stopped() { local c; for c in "${STOPPED[@]:-}"; do [ -n "$c" ] && docker start "$c" >/dev/null 2>&1; done; }
trap restore_stopped EXIT

wait_http() { # url [tentativas]
    local i; for i in $(seq 1 "${2:-60}"); do
        curl -s -o /dev/null -m 3 "$1" && return 0; sleep 2
    done; return 1
}

# ---------------------------------------------------------------- NPM
sync_npm() {
    is_running "$C_NPM" || { warn "npm: container parado"; return 2; }
    docker exec -i -e ADMIN_PASSWORD "$C_NPM" node - <<'JS'
const bcrypt = require('/app/node_modules/bcrypt');
const db = require('/app/node_modules/better-sqlite3')('/data/database.sqlite');
const users = db.prepare("select id,email,roles from user where is_deleted=0 and is_disabled=0").all()
  .filter(u => (JSON.parse(u.roles || '[]')).includes('admin'));
if (!users.length) { console.log('NOUSERS'); process.exit(3); }
const hash = bcrypt.hashSync(process.env.ADMIN_PASSWORD, 13);
const up = db.prepare("update auth set secret=?, modified_on=datetime('now') where user_id=? and type='password'");
for (const u of users) { up.run(hash, u.id); console.log('npm admin:', u.email); }
JS
    local rc=$?
    [ $rc = 3 ] && warn "npm: sem admin (suba com INITIAL_ADMIN_EMAIL/PASSWORD do compose)"
    return $rc
}

# ---------------------------------------------------------------- Portainer
sync_portainer() {
    local code
    wait_http "$PORTAINER_URL/api/status" 15
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$PORTAINER_URL/api/users/admin/check") || true
    case "$code" in
        404) # instalação nova: cria o admin
            local body
            body=$(jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Username:$u,Password:$p}')
            # versões novas exigem o token impresso nos logs do 1º boot
            local token
            token=$(docker logs "$C_PORTAINER" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' \
                | sed -n 's/^setup_token=//p' | tail -1)
            curl -sf -m 10 -X POST -H 'content-type: application/json' \
                ${token:+-H "X-Setup-Token: $token"} -d "$body" \
                "$PORTAINER_URL/api/users/admin/init" >/dev/null || return 1
            echo "portainer admin criado: $ADMIN_USER"; return 0 ;;
        204) ;;
        *) warn "portainer: API indisponível em $PORTAINER_URL (HTTP $code)"; return 2 ;;
    esac

    # admin existente: helper oficial gera senha temporária (exige container parado)
    local out tmp user
    stop_c "$C_PORTAINER" || return 1
    out=$(docker run --rm -v "$(realpath "$DIR_PORTAINER"):/data" "$HELPER_RESET_IMAGE" 2>&1)
    start_c "$C_PORTAINER"
    tmp=$(sed -n 's/.*password to login: //p' <<<"$out" | tr -d '\r' | tail -1)
    user=$(sed -n 's/.*for user: *//p' <<<"$out" | tr -d '\r' | tail -1)
    [ -n "$tmp" ] && [ -n "$user" ] || { err "portainer: helper não devolveu senha temporária"; return 1; }
    wait_http "$PORTAINER_URL/api/status" 30 || return 1

    local jwt ids id
    jwt=$(jq -n --arg u "$user" --arg p "$tmp" '{Username:$u,Password:$p}' \
        | curl -sf -m 10 -X POST -H 'content-type: application/json' -d @- "$PORTAINER_URL/api/auth" | jq -r .jwt) || return 1
    [ -n "$jwt" ] && [ "$jwt" != null ] || return 1
    ids=$(curl -sf -m 10 -H "Authorization: Bearer $jwt" "$PORTAINER_URL/api/users" | jq -r '.[]|select(.Role==1)|"\(.Id) \(.Username)"')
    while read -r id name; do
        [ -n "$id" ] || continue
        jq -n --arg p "$ADMIN_PASSWORD" '{newPassword:$p}' \
            | curl -sf -m 10 -X PUT -H "Authorization: Bearer $jwt" -H 'content-type: application/json' \
                -d @- "$PORTAINER_URL/api/users/$id" >/dev/null || return 1
        echo "portainer admin: $name"
    done <<<"$ids"
}

# ---------------------------------------------------------------- Filebrowser
sync_filebrowser() {
    local image dir fb n=0 u
    docker inspect "$C_FILEBROWSER" >/dev/null 2>&1 || { warn "filebrowser: container inexistente"; return 2; }
    image=$(docker inspect -f '{{.Config.Image}}' "$C_FILEBROWSER")
    dir=$(realpath "$DIR_FILEBROWSER") || return 1
    stop_c "$C_FILEBROWSER" || return 1
    fb=(docker run --rm --user "$PUID:$PGID" -v "$dir:/database" --entrypoint filebrowser "$image")
    local json
    "${fb[@]}" users export /database/.users-export.json -d /database/filebrowser.db >/dev/null 2>&1
    json="$dir/.users-export.json"
    local admins=""
    [ -f "$json" ] && admins=$(jq -r '.[]|select(.perm.admin==true)|.username' "$json")
    rm -f "$json"
    if [ -z "$admins" ]; then
        "${fb[@]}" users add "$ADMIN_USER" "$ADMIN_PASSWORD" --perm.admin -d /database/filebrowser.db >/dev/null 2>&1 \
            || { start_c "$C_FILEBROWSER"; return 1; }
        echo "filebrowser admin criado: $ADMIN_USER"
    else
        while read -r u; do
            [ -n "$u" ] || continue
            "${fb[@]}" users update "$u" -p "$ADMIN_PASSWORD" -d /database/filebrowser.db >/dev/null 2>&1 \
                || { start_c "$C_FILEBROWSER"; return 1; }
            echo "filebrowser admin: $u"
        done <<<"$admins"
    fi
    start_c "$C_FILEBROWSER"
}

# ---------------------------------------------------------------- code-server
sync_vscode() {
    echo "vscode: senha vem do compose (PASSWORD: \${ADMIN_PASSWORD}); rode 'make reload' para recriar o container."
}

# ---------------------------------------------------------------- Syncthing
sync_syncthing() {
    is_running "$C_SYNCTHING" || { warn "syncthing: container parado"; return 2; }
    docker exec -e ADMIN_PASSWORD -e ADMIN_USER "$C_SYNCTHING" sh -c '
        set -e
        st() { syncthing cli --home /config "$@"; }
        [ -n "$(st config gui user get)" ] || st config gui user set "$ADMIN_USER"
        st config gui password set "$ADMIN_PASSWORD"
        echo "syncthing admin: $(st config gui user get)"'
}

# ---------------------------------------------------------------- qBittorrent
sync_qbittorrent() {
    local conf="$DIR_QBITTORRENT/qBittorrent/qBittorrent.conf" i
    docker inspect "$C_QBITTORRENT" >/dev/null 2>&1 || { warn "qbittorrent: container inexistente"; return 2; }
    for i in $(seq 1 15); do [ -f "$conf" ] && break; sleep 2; done
    [ -f "$conf" ] || { warn "qbittorrent: $conf ainda não existe"; return 2; }
    stop_c "$C_QBITTORRENT" || return 1   # o app reescreve o .conf ao sair
    CONF="$conf" python3 - <<'PY' || { start_c "$C_QBITTORRENT"; return 1; }
import base64, hashlib, os, re
path = os.environ["CONF"]
salt = os.urandom(16)
key = hashlib.pbkdf2_hmac("sha512", os.environ["ADMIN_PASSWORD"].encode(), salt, 100000, 64)
val = "@ByteArray(%s:%s)" % (base64.b64encode(salt).decode(), base64.b64encode(key).decode())
lines = open(path, encoding="utf-8").read().splitlines()
had_user = any(l.startswith("WebUI\\Username=") for l in lines)
lines = [l for l in lines if not l.startswith("WebUI\\Password_PBKDF2=")]
new = []
if not had_user:
    new.append("WebUI\\Username=" + os.environ["ADMIN_USER"])
new.append("WebUI\\Password_PBKDF2=" + val)
for idx, l in enumerate(lines):
    if l.strip() == "[Preferences]":
        lines[idx + 1:idx + 1] = new
        break
else:
    lines += ["", "[Preferences]"] + new
open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")
print("qbittorrent admin atualizado")
PY
    start_c "$C_QBITTORRENT"
}

# ---------------------------------------------------------------- Jellyfin
sync_jellyfin() {
    docker inspect "$C_JELLYFIN" >/dev/null 2>&1 || { warn "jellyfin: container inexistente"; return 2; }
    local wizard
    wizard=$(curl -s -m 5 "$JELLYFIN_URL/System/Info/Public" | jq -r '[.StartupWizardCompleted, .startupWizardCompleted] | map(select(. != null)) | first | tostring')
    if [ "$wizard" = "false" ]; then # instalação nova: roda o wizard
        local H='content-type: application/json'
        curl -sf -m 10 -X POST -H "$H" -d '{"UICulture":"pt-BR","MetadataCountryCode":"BR","PreferredMetadataLanguage":"pt"}' "$JELLYFIN_URL/Startup/Configuration" >/dev/null || true
        curl -s -m 10 "$JELLYFIN_URL/Startup/User" >/dev/null || true
        jq -n --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Name:$u,Password:$p}' \
            | curl -sf -m 10 -X POST -H "$H" -d @- "$JELLYFIN_URL/Startup/User" >/dev/null || return 1
        curl -sf -m 10 -X POST -H "$H" -d '{"EnableRemoteAccess":true}' "$JELLYFIN_URL/Startup/RemoteAccess" >/dev/null || true
        curl -sf -m 10 -X POST "$JELLYFIN_URL/Startup/Complete" >/dev/null || return 1
        echo "jellyfin admin criado: $ADMIN_USER"; return 0
    fi
    local db="$DIR_JELLYFIN/data/data/jellyfin.db"
    [ -f "$db" ] || { warn "jellyfin: $db não encontrado"; return 2; }
    stop_c "$C_JELLYFIN" || return 1
    DB="$db" python3 - <<'PY' || { start_c "$C_JELLYFIN"; return 1; }
import hashlib, os, sqlite3
db = sqlite3.connect(os.environ["DB"])
admins = db.execute(
    "select u.Id, u.Username from Users u join Permissions p on p.UserId=u.Id "
    "where p.Kind=0 and p.Value=1").fetchall()
if not admins:
    raise SystemExit("jellyfin: nenhum administrador")
for uid, name in admins:
    salt = os.urandom(16)
    h = hashlib.pbkdf2_hmac("sha512", os.environ["ADMIN_PASSWORD"].encode(), salt, 210000, 64)
    val = "$PBKDF2-SHA512$iterations=210000$%s$%s" % (salt.hex().upper(), h.hex().upper())
    db.execute("update Users set Password=?, MustUpdatePassword=0, InvalidLoginAttemptCount=0 where Id=?", (val, uid))
    print("jellyfin admin:", name)
db.commit()
PY
    start_c "$C_JELLYFIN"
}

# ---------------------------------------------------------------- Uptime Kuma
sync_kuma() {
    is_running "$C_KUMA" || { warn "uptime-kuma: container parado"; return 2; }
    local res
    res=$(docker exec -i -e ADMIN_PASSWORD -e ADMIN_USER "$C_KUMA" node - <<'JS'
const { io } = require('/app/node_modules/socket.io-client');
const s = io('http://127.0.0.1:3001', { reconnection: false, timeout: 5000 });
s.on('connect_error', () => { console.log('UNREACHABLE'); process.exit(1); });
s.on('connect', () => s.emit('needSetup', (need) => {
  if (!need) { console.log('EXISTS'); process.exit(0); }
  s.emit('setup', process.env.ADMIN_USER, process.env.ADMIN_PASSWORD, (r) => {
    console.log(r && r.ok ? 'CREATED' : 'FAIL ' + (r && r.msg)); process.exit(r && r.ok ? 0 : 1);
  });
}));
JS
    )
    case "$res" in
        CREATED) echo "uptime-kuma admin criado: $ADMIN_USER" ;;
        EXISTS)
            # lê a senha do ambiente do container para não aparecer no argv do host
            res=$(docker exec -e ADMIN_PASSWORD "$C_KUMA" sh -c \
                'node extra/reset-password.js --new-password="$ADMIN_PASSWORD"' 2>&1)
            grep -q "Password reset successfully" <<<"$res" || { err "uptime-kuma: reset falhou"; return 1; }
            echo "uptime-kuma admin atualizado" ;;
        *) err "uptime-kuma: $res"; return 1 ;;
    esac
}

# ---------------------------------------------------------------- Crafty
sync_crafty() {
    is_running "$C_CRAFTY" || { warn "crafty: container parado"; return 2; }
    docker exec -i -e ADMIN_PASSWORD "$C_CRAFTY" /crafty/.venv/bin/python - <<'PY'
import os, sqlite3
from argon2 import PasswordHasher
db = sqlite3.connect("/crafty/app/config/db/crafty.sqlite", timeout=10)
rows = db.execute("select user_id, username from users where superuser=1").fetchall()
if not rows:
    raise SystemExit("crafty: nenhum superusuário")
h = PasswordHasher().hash(os.environ["ADMIN_PASSWORD"])
for uid, name in rows:
    db.execute("update users set password=? where user_id=?", (h, uid))
    print("crafty admin:", name)
db.commit()
PY
}

ALL=(npm portainer filebrowser vscode syncthing qbittorrent jellyfin kuma crafty)
TARGETS=("$@"); [ ${#TARGETS[@]} -gt 0 ] || TARGETS=("${ALL[@]}")

FAILED=()
for svc in "${TARGETS[@]}"; do
    declare -F "sync_$svc" >/dev/null || { err "serviço desconhecido: $svc (use: ${ALL[*]})"; exit 1; }
    info "[$svc]"
    "sync_$svc"; rc=$?
    if [ $rc = 0 ]; then ok "$svc"; elif [ $rc = 2 ]; then :; else err "$svc falhou"; FAILED+=("$svc"); fi
done

if [ ${#FAILED[@]} -gt 0 ]; then err "Falharam: ${FAILED[*]}"; exit 1; fi
ok "ADMIN_PASSWORD aplicada."

#!/usr/bin/env bash
# Configura o DeepSeek Harness (dsh web) como serviço systemd de usuário,
# sem Docker/imagem. Idempotente: pode rodar de novo para reconfigurar.
#
# Como funciona:
#   - O `dsh web` padrão recusa --host 0.0.0.0. O plugin `dsh-web-startup-auth`
#     libera 0.0.0.0 e adiciona login usuário/senha (cookie assinado).
#   - Escutando em 0.0.0.0 o acesso funciona pela LAN (192.168.x.x) e pelo
#     IP do Tailscale (100.x.x.x) sem proxy extra.
#   - Credenciais ficam em ~/.dsh/web-auth.json (hash scrypt, modo 0600).
#
# Uso no servidor:
#   DSH_WEB_USER=johnywalves DSH_WEB_PASSWORD='...' ./scripts/setup-dsh.sh
# Uso a partir de outra máquina (envia o script por SSH):
#   DSH_WEB_USER=... DSH_WEB_PASSWORD=... ./scripts/setup-dsh.sh --remote usuario@192.168.0.167
#
# Opções:  --upgrade         atualiza dsh e plugin de login
#          --reset-password  troca a senha existente (invalida sessões)
#          --status          mostra estado e URLs
#          --uninstall       remove o serviço (mantém dados em ~/.dsh)
# Variáveis: DSH_PORT (3080)  DSH_WORKDIR (workspace do dsh)
#            DSH_WEB_USER / DSH_WEB_PASSWORD (obrigatórias no 1º uso)
# A senha nunca é gravada neste repositório; passe só pelo ambiente.

set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${YELLOW}==>${NC} $*"; }
ok()   { echo -e "${GREEN}OK${NC}  $*"; }
warn() { echo -e "${YELLOW}AVISO${NC} $*"; }
die()  { echo -e "${RED}ERRO${NC} $*" >&2; exit 1; }

SCRIPT_PATH=""
[ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] && SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------- modo remoto
if [ "${1:-}" = "--remote" ]; then
    TARGET="${2:-}"; [ -n "$TARGET" ] || die "uso: $0 --remote usuario@host [opções]"
    shift 2
    [ -n "$SCRIPT_PATH" ] || die "--remote exige o script em disco"
    info "Executando em $TARGET via SSH..."
    ENV_PREFIX=""
    for v in DSH_PORT DSH_WORKDIR DSH_WEB_USER DSH_WEB_PASSWORD; do
        [ -n "${!v:-}" ] && ENV_PREFIX+="$v=$(printf '%q' "${!v}") "
    done
    exec ssh "$TARGET" "${ENV_PREFIX}bash -s -- $*" < "$SCRIPT_PATH"
fi

# ------------------------------------------------------------------ parâmetros
UPGRADE=0; RESET=0; ACTION=install
for arg in "$@"; do
    case "$arg" in
        --upgrade)        UPGRADE=1 ;;
        --reset-password) RESET=1 ;;
        --status)         ACTION=status ;;
        --uninstall)      ACTION=uninstall ;;
        -h|--help)        [ -n "$SCRIPT_PATH" ] && sed -n '2,26p' "$SCRIPT_PATH"; exit 0 ;;
        *) die "opção desconhecida: $arg" ;;
    esac
done

PORT="${DSH_PORT:-3080}"
UNIT_DIR="$HOME/.config/systemd/user"
SVC="dsh-web.service"
AUTH_PKG="dsh-web-startup-auth"
PROFILE_DIR="$HOME/.dsh/profiles/web"

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
command -v systemctl >/dev/null || die "systemctl não encontrado"
systemctl --user show-environment >/dev/null 2>&1 \
    || die "systemd de usuário indisponível (use login SSH/console, não sudo)"

lan_ip() { ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1; }
ts_ip()  { tailscale ip -4 2>/dev/null | head -1 || true; }

show_urls() {
    echo "LAN:       http://$(lan_ip):$PORT/"
    local t; t="$(ts_ip)"
    [ -n "$t" ] && echo "Tailscale: http://$t:$PORT/"
    return 0
}

# ------------------------------------------------------------------ status/rm
if [ "$ACTION" = status ]; then
    systemctl --user --no-pager status "$SVC" 2>&1 | sed -n '1,8p' || true
    ss -tln | grep -E ":$PORT\b" || warn "porta $PORT não está em escuta"
    show_urls; exit 0
fi
if [ "$ACTION" = uninstall ]; then
    systemctl --user disable --now "$SVC" 2>/dev/null || true
    rm -f "$UNIT_DIR/$SVC"; systemctl --user daemon-reload
    ok "Serviço removido (dados em ~/.dsh preservados)"; exit 0
fi

# ------------------------------------------------------------------ Node + dsh
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
if ! command -v node >/dev/null; then
    info "Instalando NVM + Node LTS..."
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    # shellcheck disable=SC1091
    . "$NVM_DIR/nvm.sh"; nvm install --lts
fi
NODE_BIN="$(command -v node)"; NODE_DIR="$(dirname "$NODE_BIN")"
DSH_JS="$(npm root -g)/@deepseek-ai/dsh/lib/bin.js"

if [ ! -f "$DSH_JS" ] || [ "$UPGRADE" = 1 ]; then
    info "Instalando/atualizando @deepseek-ai/dsh..."
    npm install -g @deepseek-ai/dsh
fi
[ -f "$DSH_JS" ] || die "dsh não encontrado em $DSH_JS"
ok "dsh $("$NODE_BIN" "$DSH_JS" --version)"

WORKDIR="${DSH_WORKDIR:-}"
[ -z "$WORKDIR" ] && [ -f "$UNIT_DIR/$SVC" ] && WORKDIR="$(sed -n 's/^WorkingDirectory=//p' "$UNIT_DIR/$SVC" | head -1)"
[ -z "$WORKDIR" ] && [ -n "$SCRIPT_PATH" ] && WORKDIR="$(dirname "$(dirname "$SCRIPT_PATH")")"
WORKDIR="${WORKDIR:-$HOME}"
[ -d "$WORKDIR" ] || die "workspace inexistente: $WORKDIR"

dsh() { (cd "$WORKDIR" && "$NODE_BIN" "$DSH_JS" "$@"); }

# ------------------------------------------------- plugin de login (0.0.0.0)
if [ ! -d "$PROFILE_DIR/node_modules/$AUTH_PKG" ] || [ "$UPGRADE" = 1 ]; then
    info "Instalando plugin $AUTH_PKG no perfil web..."
    dsh plugin --profile web add "$AUTH_PKG"
fi
[ -d "$PROFILE_DIR/node_modules/$AUTH_PKG" ] || die "plugin $AUTH_PKG não instalado"
ok "plugin $AUTH_PKG presente"

# ---------------------------------------------------------------- credenciais
AUTH_FILE="$HOME/.dsh/web-auth.json"
NEED_REGISTER=0
if [ ! -f "$AUTH_FILE" ]; then
    [ -n "${DSH_WEB_USER:-}" ] && [ -n "${DSH_WEB_PASSWORD:-}" ] \
        || die "primeiro uso: defina DSH_WEB_USER e DSH_WEB_PASSWORD (mín. 8 caracteres)"
    NEED_REGISTER=1
elif [ "$RESET" = 1 ]; then
    [ -n "${DSH_WEB_PASSWORD:-}" ] || die "--reset-password exige DSH_WEB_PASSWORD"
    info "Trocando senha (sessões antigas serão invalidadas)..."
    dsh --profile web auth-reset --password "$DSH_WEB_PASSWORD"
fi

# -------------------------------------------------------------------- serviço
mkdir -p "$UNIT_DIR"
STAMP="$(date +%Y%m%d%H%M%S)"
[ -f "$UNIT_DIR/$SVC" ] && cp "$UNIT_DIR/$SVC" "$UNIT_DIR/$SVC.bak.$STAMP"

cat > "$UNIT_DIR/$SVC" <<EOF
[Unit]
Description=DeepSeek Harness web service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$WORKDIR
Environment=HOME=$HOME
Environment=PATH=$NODE_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$NODE_BIN $DSH_JS web --host 0.0.0.0 --port $PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF

info "Reiniciando $SVC..."
systemctl --user daemon-reload
systemctl --user enable "$SVC" >/dev/null 2>&1
systemctl --user restart "$SVC"

READY=0
for _ in $(seq 1 45); do
    if [ "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$PORT/login" || true)" = 200 ]; then READY=1; break; fi
    if ! systemctl --user is-active --quiet "$SVC"; then break; fi
    sleep 1
done
if [ "$READY" = 0 ]; then
    journalctl --user -u "$SVC" -n 15 --no-pager >&2 || true
    if [ -f "$UNIT_DIR/$SVC.bak.$STAMP" ]; then
        mv -f "$UNIT_DIR/$SVC.bak.$STAMP" "$UNIT_DIR/$SVC"
        systemctl --user daemon-reload; systemctl --user restart "$SVC" || true
        die "serviço não ficou pronto; unit anterior restaurada"
    fi
    die "serviço não ficou pronto"
fi

if [ "$NEED_REGISTER" = 1 ]; then
    info "Registrando administrador '$DSH_WEB_USER'..."
    BODY="$(DSH_U="$DSH_WEB_USER" DSH_P="$DSH_WEB_PASSWORD" "$NODE_BIN" -e \
        'console.log(JSON.stringify({username:process.env.DSH_U,password:process.env.DSH_P}))')"
    R="$(curl -s -m 10 -X POST -H 'content-type: application/json' -d "$BODY" "http://127.0.0.1:$PORT/api/auth/register")"
    echo "$R" | grep -q '"ok":true' || die "registro falhou: $R"
fi

# Inicia no boot sem login interativo.
if [ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" != "yes" ]; then
    loginctl enable-linger "$USER" 2>/dev/null || warn "rode: sudo loginctl enable-linger $USER"
fi

# ------------------------------------------------------------------ validação
FAIL=0
for ip in 127.0.0.1 "$(lan_ip)" "$(ts_ip)"; do
    [ -z "$ip" ] && continue
    c="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$ip:$PORT/login" || echo 000)"
    if [ "$c" = 200 ]; then ok "http://$ip:$PORT/login -> $c"; else warn "http://$ip:$PORT/login -> $c"; FAIL=1; fi
done
[ -n "$(ts_ip)" ] || warn "Tailscale sem IP: rode 'sudo tailscale up' para acesso remoto"

echo; echo -e "${GREEN}=== DeepSeek Harness pronto ===${NC}"
show_urls
echo "Login com o usuário/senha definidos. Sem HTTPS: use só em LAN/Tailscale (Tailscale já é cifrado)."
echo "Firewall (se ufw ativo): sudo ufw allow $PORT/tcp"
exit "$FAIL"

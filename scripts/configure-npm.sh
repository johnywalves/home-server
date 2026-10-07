#!/usr/bin/env bash
set -e

# Carregar variáveis do .env
if [ -f .env ]; then
    export $(grep -v '^#' .env | xargs)
fi

if [ -z "$DOMAIN_NAME" ] || [ -z "$ADMIN_EMAIL" ]; then
    echo "❌ DOMAIN_NAME ou ADMIN_EMAIL não definidos no .env"
    exit 1
fi

NPM_API="http://localhost:81/api"
NPM_ADMIN_USER="${NPM_ADMIN_EMAIL:-admin@example.com}"
NPM_ADMIN_PASS="${NPM_ADMIN_PASSWORD:-changeme}"

echo "⏳ Aguardando Nginx Proxy Manager ficar online..."
until curl -s "$NPM_API/" > /dev/null; do
    sleep 3
done

echo "🔐 Efetuando login na API do NPM..."
LOGIN_RESPONSE=$(curl -s -X POST "$NPM_API/tokens" \
  -H "Content-Type: application/json" \
  -d '{"identity":"'"$NPM_ADMIN_USER"'","secret":"'"$NPM_ADMIN_PASS"'"}')

TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token // empty')

if [ -z "$TOKEN" ]; then
    echo "❌ Falha ao obter token. Verifique as credenciais no .env ou logue manualmente no painel (http://localhost:81) para definir a nova senha do NPM."
    exit 1
fi

get_or_create_certificate() {
    local DOMAIN=$1

    # Verifica se o certificado já existe
    local CERT_ID=$(curl -s -X GET "$NPM_API/nginx/certificates" \
      -H "Authorization: Bearer $TOKEN" \
      | jq -r '.[] | select(.domain_names[] == "'"$DOMAIN"'") | .id' | head -n1)

    if [ -n "$CERT_ID" ] && [ "$CERT_ID" != "null" ]; then
        echo "$CERT_ID"
        return
    fi

    # Tenta solicitar o certificado no Let's Encrypt
    local CERT_RESPONSE=$(curl -s -X POST "$NPM_API/nginx/certificates" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "provider": "letsencrypt",
        "domain_names": ["'"${DOMAIN}"'"],
        "meta": {
          "letsencrypt_email": "'"${ADMIN_EMAIL}"'",
          "letsencrypt_agree": true
        }
      }')

    CERT_ID=$(echo "$CERT_RESPONSE" | jq -r '.id // empty')
    echo "$CERT_ID"
}

create_proxy_host_https() {
    local SUBDOMAIN=$1
    local CONTAINER_NAME=$2
    local PORT=$3
    local WEBSOCKET=${4:-false}
    local SCHEME=${5:-http}
    local FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN_NAME}"

    echo "🌐 Registrando: ${FULL_DOMAIN} -> ${SCHEME}://${CONTAINER_NAME}:${PORT}"

    # Tenta obter certificado SSL
    local CERT_ID=$(get_or_create_certificate "${FULL_DOMAIN}")
    local FORCE_SSL=false

    if [ -n "$CERT_ID" ] && [ "$CERT_ID" != "null" ] && [ "$CERT_ID" -gt 0 ]; then
        echo "✅ SSL ativo para ${FULL_DOMAIN} (Cert ID: ${CERT_ID})"
        FORCE_SSL=true
    else
        echo "⚠️ SSL não obtido para ${FULL_DOMAIN}. Registrando como HTTP simples."
        CERT_ID=0
    fi

    # Criar Proxy Host no NPM
    curl -s -X POST "$NPM_API/nginx/proxy-hosts" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "domain_names": ["'"${FULL_DOMAIN}"'"],
        "forward_scheme": "'"${SCHEME}"'",
        "forward_host": "'"${CONTAINER_NAME}"'",
        "forward_port": '"${PORT}"',
        "access_list_id": "0",
        "certificate_id": '${CERT_ID:-0}',
        "meta": {"letsencrypt_agree": true, "letsencrypt_email": "'"${ADMIN_EMAIL}"'"},
        "advanced_config": "",
        "locations": [],
        "block_exploits": true,
        "caching_enabled": false,
        "allow_websocket_upgrade": '"${WEBSOCKET}"',
        "ssl_forced": '"${FORCE_SSL}"',
        "http2_support": true,
        "enabled": true
      }' > /dev/null
}

echo "🚀 Configurando Proxy Hosts no NPM..."

create_proxy_host_https "portainer" "portainer" 9000 true
create_proxy_host_https "files" "filebrowser" 8080 false
create_proxy_host_https "code" "vscode" 8443 true
create_proxy_host_https "jellyfin" "jellyfin" 8096 false
create_proxy_host_https "crafty" "crafty" 8443 true "https"
create_proxy_host_https "syncthing" "syncthing" 8384 false
create_proxy_host_https "status" "uptime-kuma" 3001 true
create_proxy_host_https "torrent" "qbittorrent" 8085 false

echo "✅ Todos os hosts foram processados com sucesso!"

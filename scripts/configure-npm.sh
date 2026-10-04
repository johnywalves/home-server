#!/usr/bin/env bash
set -e

# Carregar variáveis do .env
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

if [ -z "$DOMAIN_NAME" ] || [ -z "$ADMIN_EMAIL" ]; then
    echo "❌ DOMAIN_NAME ou ADMIN_EMAIL não definidos no .env"
    exit 1
fi

NPM_API="http://localhost:81/api"

echo "⏳ A aguardar que o Nginx Proxy Manager esteja pronto..."
until curl -s "$NPM_API/" > /dev/null; do
    sleep 3
done

echo "🔐 A obter token de acesso da API do NPM..."
TOKEN=$(curl -s -X POST "$NPM_API/tokens" \
  -H "Content-Type: application/json" \
  -d '{"identity":"admin@example.com","secret":"changeme"}' | grep -o '"token":"[^"]*' | grep -o '[^"]*$')

if [ -z "$TOKEN" ]; then
    echo "⚠️ Não foi possível obter o token. O NPM já pode ter sido configurado ou a palavra-passe alterada."
    exit 0
fi

# Função para solicitar certificado Let's Encrypt ou obter o existente
get_or_create_certificate() {
    local DOMAIN=$1
    
    # Verifica se já existe certificado para este domínio no NPM
    local CERT_ID=$(curl -s -X GET "$NPM_API/nginx/certificates" \
      -H "Authorization: Bearer $TOKEN" \
      | grep -o '{"id":[0-9]*,"domain_names":\["'${DOMAIN}'"' | grep -o '[0-9]*' | head -n1)

    if [ -n "$CERT_ID" ]; then
        echo $CERT_ID
        return
    fi

    # Solicita um novo certificado Let's Encrypt
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

    CERT_ID=$(echo "$CERT_RESPONSE" | grep -o '"id":[0-9]*' | head -n1 | cut -d':' -f2)
    echo $CERT_ID
}

# Função para criar Proxy Host com HTTPS forçado
create_proxy_host_https() {
    local SUBDOMAIN=$1
    local CONTAINER_NAME=$2
    local PORT=$3
    local WEBSOCKET=${4:-false}
    local SCHEME=${5:-http}
    local FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN_NAME}"

    echo "🌐 Processando: https://${FULL_DOMAIN} -> ${SCHEME}://${CONTAINER_NAME}:${PORT}"

    # 1. Tentar solicitar/obter o certificado SSL
    echo "🔒 Solicitando/verificando certificado SSL para ${FULL_DOMAIN}..."
    local CERT_ID=$(get_or_create_certificate "${FULL_DOMAIN}")

    local FORCE_SSL=false
    if [ -n "$CERT_ID" ] && [ "$CERT_ID" -gt 0 ]; then
        echo "✅ Certificado SSL obtido com sucesso (ID: ${CERT_ID}). Forçando HTTPS..."
        FORCE_SSL=true
    else
        echo "⚠️ Não foi possível obter SSL automático para ${FULL_DOMAIN} (verifique se o DNS já propagou e se as portas 80/443 estão abertas). Criando sem Force SSL por enquanto."
        CERT_ID=0
    fi

    # 2. Criar ou atualizar o Proxy Host
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

echo "🚀 A configurar os Proxy Hosts com HTTPS no Nginx Proxy Manager..."

create_proxy_host_https "portainer" "portainer" 9000 true
create_proxy_host_https "files" "filebrowser" 8080 false
create_proxy_host_https "code" "vscode" 8443 true
create_proxy_host_https "jellyfin" "jellyfin" 8096 false
create_proxy_host_https "crafty" "crafty" 8443 true "https"
create_proxy_host_https "syncthing" "syncthing" 8384 false
create_proxy_host_https "status" "uptime-kuma" 3001 true
create_proxy_host_https "torrent" "qbittorrent" 8085 false

echo "✅ Todos os subdomínios foram configurados no Nginx Proxy Manager!"
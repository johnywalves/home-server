#!/usr/bin/env bash
set -e

# Carregar variáveis do .env
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

if [ -z "$DOMAIN_NAME" ]; then
    echo "❌ DOMAIN_NAME não definido no .env"
    exit 1
fi

NPM_API="http://localhost:81/api"

echo "⏳ A aguardar que o Nginx Proxy Manager esteja pronto..."
until curl -s "$NPM_API/" > /dev/null; do
    sleep 3
done

echo "🔐 A obter token de acesso da API do NPM..."
# Credenciais padrão de primeiro acesso do NPM: admin@example.com / changeme
TOKEN=$(curl -s -X POST "$NPM_API/tokens" \
  -H "Content-Type: application/json" \
  -d '{"identity":"admin@example.com","secret":"changeme"}' | grep -o '"token":"[^"]*' | grep -o '[^"]*$')

if [ -z "$TOKEN" ]; then
    echo "⚠️ Não foi possível obter o token. O NPM já pode ter sido configurado ou a palavra-passe alterada."
    exit 0
fi

# Função para criar Proxy Host no NPM
create_proxy_host() {
    local SUBDOMAIN=$1
    local CONTAINER_NAME=$2
    local PORT=$3
    local WEBSOCKET=${4:-false}

    echo "🌐 A criar mapeamento: ${SUBDOMAIN}.${DOMAIN_NAME} -> ${CONTAINER_NAME}:${PORT}"

    curl -s -X POST "$NPM_API/nginx/proxy-hosts" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "domain_names": ["'"${SUBDOMAIN}.${DOMAIN_NAME}"'"],
        "forward_scheme": "http",
        "forward_host": "'"${CONTAINER_NAME}"'",
        "forward_port": '"${PORT}"',
        "access_list_id": "0",
        "certificate_id": 0,
        "meta": {"letsencrypt_agree": false},
        "advanced_config": "",
        "locations": [],
        "block_exploits": true,
        "caching_enabled": false,
        "allow_websocket_upgrade": '"${WEBSOCKET}"',
        "http2_support": true,
        "enabled": true
      }' > /dev/null
}

echo "🚀 A configurar os Proxy Hosts no Nginx Proxy Manager..."

# Mapeamento dos serviços do docker-compose.yml
create_proxy_host "portainer" "portainer" 9000 true
create_proxy_host "files" "filebrowser" 80 false
create_proxy_host "code" "vscode" 8443 true
create_proxy_host "jellyfin" "jellyfin" 8096 false
create_proxy_host "crafty" "crafty" 8443 true
create_proxy_host "syncthing" "syncthing" 8384 false

echo "✅ Todos os subdomínios foram mapeados com sucesso no Nginx Proxy Manager!"
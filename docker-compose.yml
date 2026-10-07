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
    echo "❌ Falha ao obter token. Verifique as credenciais no .env ou logue no painel web (http://localhost:81) para trocar a senha padrão."
    exit 1
fi

create_or_update_proxy_host() {
    local SUBDOMAIN=$1
    local CONTAINER_NAME=$2
    local PORT=$3
    local WEBSOCKET=${4:-false}
    local SCHEME=${5:-http}
    
    # Se SUBDOMAIN for vazio ou "@", usa diretamente DOMAIN_NAME (Naked Domain)
    local FULL_DOMAIN
    if [ -z "$SUBDOMAIN" ] || [ "$SUBDOMAIN" == "@" ]; then
        FULL_DOMAIN="${DOMAIN_NAME}"
    else
        FULL_DOMAIN="${SUBDOMAIN}.${DOMAIN_NAME}"
    fi

    echo "🌐 Processando: ${FULL_DOMAIN} -> ${SCHEME}://${CONTAINER_NAME}:${PORT}"

    # 1. Verifica se o Proxy Host já existe no NPM
    local HOST_ID=$(curl -s -X GET "$NPM_API/nginx/proxy-hosts" \
      -H "Authorization: Bearer $TOKEN" \
      | jq -r '.[] | select(.domain_names[] == "'"$FULL_DOMAIN"'") | .id' | head -n1)

    # 2. Cria o Proxy Host sem SSL primeiro para poder passar na validação ACME/Let's Encrypt
    if [ -z "$HOST_ID" ] || [ "$HOST_ID" == "null" ]; then
        echo "➕ Criando Proxy Host HTTP para ${FULL_DOMAIN}..."
        HOST_RESPONSE=$(curl -s -X POST "$NPM_API/nginx/proxy-hosts" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d '{
            "domain_names": ["'"${FULL_DOMAIN}"'"],
            "forward_scheme": "'"${SCHEME}"'",
            "forward_host": "'"${CONTAINER_NAME}"'",
            "forward_port": '"${PORT}"',
            "access_list_id": "0",
            "certificate_id": 0,
            "meta": {},
            "advanced_config": "",
            "locations": [],
            "block_exploits": true,
            "caching_enabled": false,
            "allow_websocket_upgrade": '"${WEBSOCKET}"',
            "ssl_forced": false,
            "http2_support": true,
            "enabled": true
          }')
        HOST_ID=$(echo "$HOST_RESPONSE" | jq -r '.id // empty')
    fi

    if [ -z "$HOST_ID" ] || [ "$HOST_ID" == "null" ]; then
        echo "❌ Erro ao criar o Proxy Host para ${FULL_DOMAIN}."
        return 1
    fi

    # 3. Solicita o Certificado SSL Let's Encrypt
    echo "🔒 Solicitando Certificado SSL Let's Encrypt para ${FULL_DOMAIN}..."
    CERT_RESPONSE=$(curl -s -X POST "$NPM_API/nginx/certificates" \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "provider": "letsencrypt",
        "domain_names": ["'"${FULL_DOMAIN}"'"],
        "meta": {
          "letsencrypt_email": "'"${ADMIN_EMAIL}"'",
          "letsencrypt_agree": true
        }
      }')

    CERT_ID=$(echo "$CERT_RESPONSE" | jq -r '.id // empty')

    # 4. Se o certificado foi emitido, vincula ao Proxy Host e ativa Force SSL
    if [ -n "$CERT_ID" ] && [ "$CERT_ID" != "null" ] && [ "$CERT_ID" -gt 0 ]; then
        echo "✅ Certificado gerado (ID: ${CERT_ID}). Ativando HTTPS forçado..."
        curl -s -X PUT "$NPM_API/nginx/proxy-hosts/${HOST_ID}" \
          -H "Authorization: Bearer $TOKEN" \
          -H "Content-Type: application/json" \
          -d '{
            "domain_names": ["'"${FULL_DOMAIN}"'"],
            "forward_scheme": "'"${SCHEME}"'",
            "forward_host": "'"${CONTAINER_NAME}"'",
            "forward_port": '"${PORT}"',
            "access_list_id": "0",
            "certificate_id": '"${CERT_ID}"',
            "meta": {},
            "advanced_config": "",
            "locations": [],
            "block_exploits": true,
            "caching_enabled": false,
            "allow_websocket_upgrade": '"${WEBSOCKET}"',
            "ssl_forced": true,
            "http2_support": true,
            "enabled": true
          }' > /dev/null
    else
        echo "⚠️ SSL não pôde ser gerado para ${FULL_DOMAIN}. Host mantido em HTTP."
    fi
}

echo "🚀 Configurando Proxy Hosts no NPM..."

# 🏠 NAKED DOMAIN (bluedress.duckdns.org) -> Apontando para o Uptime Kuma (ou escolha outro serviço)
create_or_update_proxy_host "" "uptime-kuma" 3001 true

# 🌐 SUBDOMÍNIOS
create_or_update_proxy_host "portainer" "portainer" 9000 true
create_or_update_proxy_host "files" "filebrowser" 8080 false
create_or_update_proxy_host "code" "vscode" 8443 true
create_or_update_proxy_host "jellyfin" "jellyfin" 8096 false
create_or_update_proxy_host "crafty" "crafty" 8443 true "https"
create_or_update_proxy_host "syncthing" "syncthing" 8384 false
create_or_update_proxy_host "status" "uptime-kuma" 3001 true
create_or_update_proxy_host "torrent" "qbittorrent" 8085 false

echo "✅ Configuração concluída com sucesso!"

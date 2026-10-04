#!/usr/bin/env bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Iniciando Setup do Home Server ===${NC}"

# 1. Atualizar pacotes do sistema
echo -e "${YELLOW}[1/7] Atualizando pacotes do sistema...${NC}"
sudo apt-get update -y && sudo apt-get upgrade -y
sudo apt-get install -y curl wget git ca-certificates gnupg lsb-release build-essential

# 2. Instalar Docker se não estiver instalado
if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}[2/7] Instalando Docker...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
    
    sudo usermod -aG docker $USER
    echo -e "${GREEN}Docker instalado com sucesso!${NC}"
else
    echo -e "${GREEN}Docker já está instalado.${NC}"
fi

# 3. Instalar Tailscale se não estiver instalado
if ! command -v tailscale &> /dev/null; then
    echo -e "${YELLOW}[3/7] Instalando Tailscale...${NC}"
    curl -fsSL https://tailscale.com/install.sh | sh
    echo -e "${GREEN}Tailscale instalado com sucesso!${NC}"
else
    echo -e "${GREEN}Tailscale já está instalado.${NC}"
fi

# 4. Instalar NVM e Node.js (Versão LTS)
if [ ! -d "$HOME/.nvm" ]; then
    echo -e "${YELLOW}[4/7] Instalando NVM e Node.js LTS...${NC}"
    export NVM_DIR="$HOME/.nvm"
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    
    nvm install --lts
    nvm use --lts
    nvm alias default 'lts/*'
    echo -e "${GREEN}Node.js $(node -v) instalado com sucesso via NVM!${NC}"
else
    echo -e "${GREEN}NVM já está instalado em $HOME/.nvm.${NC}"
fi

# 5. Configurar arquivo .env e .env.example
echo -e "${YELLOW}[5/7] Configurando variáveis de ambiente...${NC}"

# Cria o .env.example se não existir
if [ ! -f .env.example ]; then
    cat <<EOF > .env.example
PUID=1000
PGID=1000
TZ=America/Sao_Paulo
DATA_DIR=./services
MEDIA_DIR=/mnt/media
EOF
fi

if [ ! -f .env ]; then
    cp .env.example .env
    sed -i "s/PUID=1000/PUID=$(id -u)/g" .env
    sed -i "s/PGID=1000/PGID=$(id -g)/g" .env
    echo -e "${GREEN}Arquivo .env criado com PUID=$(id -u) e PGID=$(id -g).${NC}"
else
    echo -e "${GREEN}Arquivo .env já existe.${NC}"
fi

# 6. Criar estrutura de pastas dos serviços e ficheiros iniciais
echo -e "${YELLOW}[6/7] Criando estrutura de dados locais...${NC}"
mkdir -p services/portainer/data
mkdir -p services/vscode/config
mkdir -p services/jellyfin/config services/jellyfin/cache
mkdir -p services/nginx-proxy-manager/data services/nginx-proxy-manager/letsencrypt
mkdir -p services/crafty/data services/crafty/servers
mkdir -p services/filebrowser/config
mkdir -p services/syncthing/config

# Inicializar ficheiros do Filebrowser para evitar que o Docker os crie como diretorias
if [ ! -f services/filebrowser/filebrowser.db ]; then
    touch services/filebrowser/filebrowser.db
fi

if [ ! -f services/filebrowser/config/settings.json ]; then
    touch services/filebrowser/config/settings.json
fi

# 7. Ativar Tailscale e Subir os Containers
echo -e "${YELLOW}[7/7] Autenticando Tailscale e subindo os containers...${NC}"
sudo tailscale up --accept-routes

echo -e "${GREEN}Subindo containers via Docker Compose...${NC}"
sudo docker compose up -d

echo "⚙️ A configurar mapeamentos no Nginx Proxy Manager..."
./scripts/configure-npm.sh

echo -e "${GREEN}=== Setup Concluído com Sucesso! ===${NC}"
echo -e "Nota: Para utilizar o comando 'nvm' ou 'node' nesta mesma sessão do terminal, rode:"
echo -e "source ~/.bashrc"
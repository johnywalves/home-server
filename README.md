# 🚀 Home Server Setup

Repositório automatizado para configuração e orquestração de um servidor doméstico em Ubuntu utilizando Docker, Docker Compose e Tailscale.

---

## 🛠️️ Serviços Incluídos

| Serviço | Descrição | Porta Local |
| :--- | :--- | :--- |
| **Portainer** | Gestão visual de containers Docker | `9000` / `9443` |
| **Nginx Proxy Manager** | Reverse proxy e gestão de certificados SSL | `80`, `81` (Painel), `443` |
| **VS Code Web** | IDE de desenvolvimento no navegador | `8440` |
| **Jellyfin** | Servidor de streaming de media | `8096` |
| **Crafty Controller** | Painel de gestão para servidores Minecraft | `8443` (Painel), `25565-25575` (Java), `19132-19135` (Bedrock) |
| **Filebrowser** | Gestor de ficheiros web com acesso ao sistema | `8080` |
| **Syncthing** | Sincronização contínua e segura de ficheiros | `8384` |
| **Tailscale** | Rede Mesh VPN para acesso remoto seguro | *Interface de rede host* |

---

## 📋 Pré-requisitos

- Sistema Operativo: **Ubuntu 20.04 LTS / 22.04 LTS / 24.04 LTS** (ou derivados Debian).
- Utilizador com privilégios de `sudo`.
- Conexão à Internet.

---

## 📁 Estrutura do Repositório

```text
home-server/
├── README.md
├── .env.example
├── docker-compose.yml
├── setup.sh              # Script de instalação automatizada
├── Makefile              # Comandos de atalho para gestão
└── services/             # Dados persistentes dos serviços
    ├── portainer/
    ├── vscode/
    ├── jellyfin/
    ├── nginx-proxy-manager/
    ├── crafty/
    ├── filebrowser/
    └── syncthing/
```

---

## ⚡ Instalação Rápida

1. **Clonar o repositório:**

```bash
git clone <URL_DO_SEU_REPOSITORIO>
cd home-server
```

2. **Executar o script de setup:**

```bash
make setup
# Ou diretamente: chmod +x setup.sh && ./setup.sh
```

O script irá automaticamente:

- Atualizar os pacotes do sistema.
- Instalar o **Docker** e **Docker Compose** (se necessário).
- Instalar e inicializar o **Tailscale**.
- Criar o ficheiro `.env` com as suas permissões (`PUID` e `PGID`).
- Criar a estrutura de pastas necessária para a persistência de dados.
- Iniciar toda a stack de containers.

---

## 🕹 Comandos Úteis (Makefile)

O repositório inclui um `Makefile` para facilitar o dia a dia:

- `make up` — Inicia todos os serviços em segundo plano.
- `make down` — Para e remove os containers da stack.
- `make restart` — Reinicia todos os containers.
- `make logs` — Acompanha os logs em tempo real.
- `make status` — Exibe o estado dos containers.
- `make update` — Atualiza as imagens dos containers para a versão mais recente.

---

## 🔐 Primeiros Passos Pós-Instalação

1. **Tailscale:** Após o setup, aceda à URL mostrada no terminal para autenticar a máquina na sua conta Tailscale.
2. **Nginx Proxy Manager:** Aceda a `http://<IP-DO-SERVIDOR>:81` (Credenciais padrão: `admin@example.com` / `changeme`).
3. **Portainer:** Aceda a `http://<IP-DO-SERVIDOR>:9000` e crie a conta do utilizador administrador.
4. **Filebrowser:** Aceda a `http://<IP-DO-SERVIDOR>:8080` (Credenciais padrão: `admin` / `admin`).
5. **Syncthing:** Aceda a `http://<IP-DO-SERVIDOR>:8384` para definir o acesso e adicionar dispositivos parceiros.

> ⚠️ Aviso de Segurança: O Filebrowser e o Syncthing estão configurados para aceder à raiz (`/`) e ao diretório `/data/host` do servidor. Certifique-se de configurar palavras-passe fortes nas respetivas interfaces de administração.

---

## 🌐 Guia de Configuração e Conferência de Subdomínios

Abaixo estão as instruções passo a passo para conferir os Apontamentos de DNS e configurar o **Nginx Proxy Manager (NPM)** para redirecionar cada subdomínio ao container correspondente na rede Docker.

### 1. Conferência dos Apontamentos de DNS

Antes de criar os Proxy Hosts no Nginx Proxy Manager, garanta que os subdomínios apontam para o IP correto da sua máquina/rede.

1. **No seu Provedor de DNS (Cloudflare, Registro.br, etc.):**

- **Registro Wildcard (Recomendado):** Crie um registro do tipo `A` com o nome `*` apontando para o seu IP público (ou IP do Tailscale / IP local).

- **Ou Registros Individuais:** Crie registros do tipo `A` para cada serviço:
  - `portainer.seudominio.com` ➔ `SEU_IP`
  - `code.seudominio.com` ➔ `SEU_IP`
  - `jellyfin.seudominio.com` ➔ `SEU_IP`
  - `crafty.seudominio.com` ➔ `SEU_IP`
  - `files.seudominio.com` ➔ `SEU_IP`
  - `sync.seudominio.com` ➔ `SEU_IP`

2. **Como Testar o Apontamento no Terminal:**

Abra o terminal e verifique se o DNS está resolvendo para o IP esperado:

```bash
ping portainer.seudominio.com
# Ou use o comando nslookup/dig:
nslookup jellyfin.seudominio.com
```

### 2. Tabela de Mapeamento para o Nginx Proxy Manager

Como todos os serviços do seu `docker-compose.yml` compartilham a mesma rede (`home-network`), o NPM conversa com eles diretamente através do **nome do container** e da **porta interna** da aplicação:

| Subdomínio Sugerido | Domain Names | Scheme | Forward Hostname / IP | Forward Port |
| :--- | :--- | :--- | :--- | :--- |
| **Portainer** | `portainer.seudominio.com` | `http` | `portainer` | `9000` |
| **VS Code Web** | `code.seudominio.com` | `http` | `vscode` | `8443` |
| **Jellyfin** | `jellyfin.seudominio.com` | `http` | `jellyfin` | `8096` |
| **Crafty Controller** | `crafty.seudominio.com` | `https` | `crafty` | `8443` |
| **Filebrowser** | `files.seudominio.com` | `http` | `filebrowser` | `8080` |
| **Syncthing** | `sync.seudominio.com` | `http` | `syncthing` | `8384` |

> **Atenção sobre o Crafty:** Como a interface web do Crafty utiliza SSL próprio por padrão, defina o *Scheme* como **`https`** para o hostname `crafty`.

### 3. Passo a Passo de Criação no NPM (Interface Web)

1. Aceda ao painel do Nginx Proxy Manager em `http://<IP-DO-SERVIDOR>:81`.
2. Vá em **Hosts** ➔ **Proxy Hosts** ➔ clique no botão **Add Proxy Host**.

#### **Aba "Details":**

- **Domain Names:** Digite o subdomínio completo (ex: `jellyfin.seudominio.com`) e pressione `Enter`.
- **Scheme:** `http` (ou `https` para o Crafty).
- **Forward Hostname / IP:** O nome do container Docker (ex: `jellyfin`).
- **Forward Port:** A porta interna do serviço (ex: `8096`).
- **Opções recomendadas:** Marque **Block Common Exploits** e **Websockets Support** (essencial para VS Code Web e Portainer).

#### **Aba "SSL":**

1. No menu suspenso *SSL Certificate*, escolha **Request a new SSL Certificate**.
2. Marque **Force SSL** e **HTTP/2 Support**.
3. Insira o seu e-mail de contacto.
4. Marque a caixa **I Agree to the Let's Encrypt Terms of Service**.
5. Clique em **Save**.

### 4. Checklist de Verificação e Resolução de Problemas

Se um subdomínio não carregar após a criação:

- [ ] **O container está na mesma rede?** Execute `docker network inspect home-server_home-network` para garantir que o NPM e o container em questão aparecem no mesmo grupo.
- [ ] **Portas 80 e 443 liberadas?** Se estiver gerando certificados Let's Encrypt via HTTP Challenge, as portas `80` e `443` do seu roteador devem estar redirecionadas para o IP do seu servidor Ubuntu.
- [ ] **Status no NPM:** Se a flag do certificado SSL no NPM ficar vermelha (Offline/Error), verifique se o apontamento de DNS já propagou completamente antes de solicitar o certificado novamente.
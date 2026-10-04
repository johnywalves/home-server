.PHONY: setup up down restart logs status update clean reload shell check

# Variáveis do Projeto
COMPOSE = docker compose
SERVICE ?= 

# Executa a instalação completa do zero
setup:
	@chmod +x setup.sh
	@./setup.sh

# Subir todos os serviços em segundo plano
up:
	$(COMPOSE) up -d

# Parar todos os serviços
down:
	$(COMPOSE) down

# Reiniciar todos os serviços (ou um serviço específico: make restart SERVICE=jellyfin)
restart:
	@if [ -n "$(SERVICE)" ]; then \
		$(COMPOSE) restart $(SERVICE); \
	else \
		$(COMPOSE) restart; \
	fi

# Ver logs de todos os containers ou de um específico (ex: make logs SERVICE=npm)
logs:
	@if [ -n "$(SERVICE)" ]; then \
		$(COMPOSE) logs -f $(SERVICE); \
	else \
		$(COMPOSE) logs -f; \
	fi

# Ver status atual dos serviços
status:
	$(COMPOSE) ps

# Recarregar as configurações do docker-compose/.env sem parar tudo
reload:
	$(COMPOSE) up -d --remove-orphans

# Atualizar imagens dos containers e reiniciar
update:
	$(COMPOSE) pull
	$(COMPOSE) up -d --remove-orphans

# Abrir um shell num container (ex: make shell SERVICE=vscode)
shell:
	@if [ -z "$(SERVICE)" ]; then \
		echo "Erro: Especifique o serviço. Exemplo: make shell SERVICE=vscode"; \
	else \
		$(COMPOSE) exec -it $(SERVICE) sh || $(COMPOSE) exec -it $(SERVICE) bash; \
	fi

# Validar ficheiros de configuração e variáveis
check:
	@if [ ! -f .env ]; then \
		echo "⚠️ Ficheiro .env não encontrado! Rode 'make setup' para gerar o .env automaticamente."; \
		exit 1; \
	fi
	@$(COMPOSE) config --quiet && echo "✅ Ficheiro docker-compose.yml e variáveis do .env válidos."

# Limpeza profunda de imagens não utilizadas e cache do Docker
clean:
	docker system prune -a --volumes -f
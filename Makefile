COMPOSE   := docker compose
DC        := $(COMPOSE) --env-file .env
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
BACKUP_DIR := backups/$(TIMESTAMP)

.DEFAULT_GOAL := help

.PHONY: help setup up down restart logs status health \
        reload-prometheus reload-nginx update backup \
        ps prune open

## ── Bootstrap ────────────────────────────────────────────────────────────────

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

setup: ## First-time setup: create .env, generate htpasswd, create SSL dir
	@echo "── Setup ──────────────────────────────────────────────"
	@if [ ! -f .env ]; then \
	  cp .env.example .env; \
	  echo "  Created .env from .env.example — edit it before continuing"; \
	else \
	  echo "  .env already exists, skipping"; \
	fi
	@mkdir -p nginx/ssl
	@if [ ! -s nginx/.htpasswd ]; then \
	  echo ""; \
	  echo "  Enter credentials for the Prometheus/Alertmanager basic-auth:"; \
	  read -p "  Username [admin]: " user; user=$${user:-admin}; \
	  docker run --rm -it httpd:alpine htpasswd -nB $$user >> nginx/.htpasswd; \
	  echo "  Written to nginx/.htpasswd"; \
	fi
	@echo ""; \
	echo "  Done. Run 'make up' to start the stack."

## ── Lifecycle ────────────────────────────────────────────────────────────────

up: ## Start all services (detached)
	$(DC) up -d --remove-orphans

down: ## Stop all services (volumes are preserved)
	$(DC) down

restart: ## Restart all services
	$(DC) restart

restart-%: ## Restart a single service  (e.g. make restart-grafana)
	$(DC) restart $*

pull: ## Pull the latest image tags pinned in docker-compose.yml
	$(DC) pull

update: pull ## Pull latest images and recreate changed containers
	$(DC) up -d --remove-orphans

## ── Observability ────────────────────────────────────────────────────────────

logs: ## Follow logs for all services (Ctrl-C to stop)
	$(DC) logs -f --tail=100

logs-%: ## Follow logs for a single service (e.g. make logs-prometheus)
	$(DC) logs -f --tail=100 $*

ps: ## Show running containers and their status
	$(DC) ps

status: ps ## Alias for ps

health: ## Print health status of every container
	@docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "NAME|$(shell $(DC) ps --services | tr '\n' '|' | sed 's/|$$//')"

## ── Config hot-reloads ───────────────────────────────────────────────────────

reload-prometheus: ## Hot-reload Prometheus config without restart
	@curl -s -X POST http://localhost:$$($(DC) port prometheus 9090 2>/dev/null | cut -d: -f2)/-/reload || \
	 docker exec prometheus kill -HUP 1
	@echo "Prometheus config reloaded"

reload-nginx: ## Hot-reload Nginx config without restart
	@docker exec nginx-proxy nginx -t && docker exec nginx-proxy nginx -s reload
	@echo "Nginx config reloaded"

check-prometheus: ## Validate prometheus.yml syntax
	docker run --rm -v $(PWD)/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
	  prom/prometheus:v2.53.0 promtool check config /etc/prometheus/prometheus.yml

check-rules: ## Validate Prometheus alerting rule files
	docker run --rm -v $(PWD)/prometheus/rules:/rules:ro \
	  prom/prometheus:v2.53.0 promtool check rules /rules/*.yml

check-alertmanager: ## Validate alertmanager.yml syntax
	docker run --rm -v $(PWD)/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro \
	  prom/alertmanager:v0.27.0 amtool check-config /etc/alertmanager/alertmanager.yml

## ── Backup & Restore ─────────────────────────────────────────────────────────

backup: ## Back up all named volumes to backups/<timestamp>/
	@echo "── Backup → $(BACKUP_DIR) ──────────────────────────────"
	@mkdir -p $(BACKUP_DIR)
	@for vol in uptime_kuma_data prometheus_data grafana_data alertmanager_data; do \
	  full=$$($(COMPOSE) config --volumes | grep $$vol | head -1); \
	  echo "  Backing up $$vol..."; \
	  docker run --rm \
	    -v monitoring_$${vol}:/data:ro \
	    -v $(PWD)/$(BACKUP_DIR):/backup \
	    alpine tar czf /backup/$${vol}.tar.gz -C /data .; \
	done
	@echo "  Done. Archives in $(BACKUP_DIR)/"

restore: ## Restore from BACKUP=backups/<timestamp> (set BACKUP env var)
	@if [ -z "$(BACKUP)" ]; then echo "Usage: make restore BACKUP=backups/20240101_120000"; exit 1; fi
	@echo "── Restore from $(BACKUP) ─────────────────────────────"
	$(DC) down
	@for vol in uptime_kuma_data prometheus_data grafana_data alertmanager_data; do \
	  if [ -f $(BACKUP)/$${vol}.tar.gz ]; then \
	    echo "  Restoring $$vol..."; \
	    docker run --rm \
	      -v monitoring_$${vol}:/data \
	      -v $(PWD)/$(BACKUP):/backup:ro \
	      alpine sh -c "rm -rf /data/* && tar xzf /backup/$${vol}.tar.gz -C /data"; \
	  fi; \
	done
	$(DC) up -d --remove-orphans
	@echo "  Restore complete."

## ── Utilities ────────────────────────────────────────────────────────────────

prune: ## Remove stopped containers and dangling images
	docker container prune -f
	docker image prune -f

open: ## Open the monitoring dashboard in the default browser
	@python3 -m webbrowser http://localhost/ 2>/dev/null || \
	 xdg-open http://localhost/ 2>/dev/null || \
	 open http://localhost/ 2>/dev/null || \
	 echo "Open http://localhost/ in your browser"

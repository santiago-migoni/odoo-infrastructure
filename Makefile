.DEFAULT_GOAL := help

COMPOSE_PROD       := docker compose -f docker/docker-compose.prod.yml
COMPOSE_STAGING    := docker compose -f docker/docker-compose.staging.yml
COMPOSE_EDGE       := docker compose -f docker/docker-compose.edge.yml
COMPOSE_MONITORING := docker compose -f docker/docker-compose.monitoring.yml
COMPOSE_BACKUP     := docker compose -f docker/docker-compose.backup.yml

PROD_SERVICES       := db pgbouncer odoo
STAGING_SERVICES    := db pgbouncer odoo-staging postgres-exporter
EDGE_SERVICES       := traefik cloudflared
MONITORING_SERVICES := prometheus grafana loki promtail cadvisor node-exporter postgres-exporter-prod
BACKUP_SERVICES     := backup

define svc-target
$(1)-$(2)-up:
	$$(COMPOSE_$(3)) up -d $(2)
$(1)-$(2)-stop:
	$$(COMPOSE_$(3)) stop $(2)
$(1)-$(2)-restart:
	$$(COMPOSE_$(3)) restart $(2)
$(1)-$(2)-logs:
	$$(COMPOSE_$(3)) logs -f $(2)
.PHONY: $(1)-$(2)-up $(1)-$(2)-stop $(1)-$(2)-restart $(1)-$(2)-logs
endef

$(foreach svc,$(PROD_SERVICES),$(eval $(call svc-target,prod,$(svc),PROD)))
$(foreach svc,$(STAGING_SERVICES),$(eval $(call svc-target,staging,$(svc),STAGING)))
$(foreach svc,$(EDGE_SERVICES),$(eval $(call svc-target,edge,$(svc),EDGE)))
$(foreach svc,$(MONITORING_SERVICES),$(eval $(call svc-target,monitoring,$(svc),MONITORING)))
$(foreach svc,$(BACKUP_SERVICES),$(eval $(call svc-target,backup,$(svc),BACKUP)))

# pull: solo imágenes oficiales — excluye odoo, odoo-staging y backup (build propio)
PROD_PULL_SERVICES       := db pgbouncer
STAGING_PULL_SERVICES    := db pgbouncer postgres-exporter
EDGE_PULL_SERVICES       := traefik cloudflared
MONITORING_PULL_SERVICES := prometheus grafana loki promtail cadvisor node-exporter postgres-exporter-prod

define pull-target
$(1)-$(2)-pull:
	$$(COMPOSE_$(3)) pull $(2)
.PHONY: $(1)-$(2)-pull
endef

$(foreach svc,$(PROD_PULL_SERVICES),$(eval $(call pull-target,prod,$(svc),PROD)))
$(foreach svc,$(STAGING_PULL_SERVICES),$(eval $(call pull-target,staging,$(svc),STAGING)))
$(foreach svc,$(EDGE_PULL_SERVICES),$(eval $(call pull-target,edge,$(svc),EDGE)))
$(foreach svc,$(MONITORING_PULL_SERVICES),$(eval $(call pull-target,monitoring,$(svc),MONITORING)))

# rebuild: solo servicios con build propio (odoo, odoo-staging)
prod-odoo-rebuild:
	$(COMPOSE_PROD) build --no-cache odoo
	$(COMPOSE_PROD) up -d odoo

staging-odoo-staging-rebuild:
	$(COMPOSE_STAGING) build --no-cache odoo-staging
	$(COMPOSE_STAGING) up -d odoo-staging

.PHONY: prod-odoo-rebuild staging-odoo-staging-rebuild

# Compuestos de stack completo (up/down genéricos: docker compose crudo)
define stack-target
$(1)-up:
	$$(COMPOSE_$(2)) up -d
$(1)-down:
	$$(COMPOSE_$(2)) down
$(1)-status:
	$$(COMPOSE_$(2)) ps
$(1)-logs:
	$$(COMPOSE_$(2)) logs -f
.PHONY: $(1)-up $(1)-down $(1)-status $(1)-logs
endef

# status/logs genéricos también sirven para staging (solo lectura); up/down
# de staging NO usan este template — staging-up/staging-down son los
# especiales de más abajo (ciclo crítico restore+anonimización, nunca un
# `docker compose up -d` crudo que arrancaría Odoo sin anonimizar)
define stack-readonly-target
$(1)-status:
	$$(COMPOSE_$(2)) ps
$(1)-logs:
	$$(COMPOSE_$(2)) logs -f
.PHONY: $(1)-status $(1)-logs
endef

$(eval $(call stack-target,prod,PROD))
$(eval $(call stack-readonly-target,staging,STAGING))
$(eval $(call stack-target,edge,EDGE))
$(eval $(call stack-target,monitoring,MONITORING))
$(eval $(call stack-target,backup,BACKUP))

help:
	@echo "Compuestos de stack:  <stack>-up | <stack>-down | <stack>-status | <stack>-logs"
	@echo "  stacks: prod staging edge monitoring backup"
	@echo ""
	@echo "Rebuild (build propio):  prod-odoo-rebuild | staging-odoo-staging-rebuild"
	@echo ""
	@echo "Especiales:"
	@echo "  staging-up | staging-down | staging-db-restore (alias de staging-up)"
	@echo "  backup | backup-backup-run"
	@echo "  setup-backup-role | setup-monitoring-role"
	@echo "  prod-db-restore CONFIRM=yes [LOCAL=yes]   -- destructivo, disaster recovery"
	@echo ""
	@echo "Por servicio: <stack>-<servicio>-<up|stop|restart|logs>, + -pull (imagen oficial) / -rebuild (build propio)"
	@echo "  prod:       $(PROD_SERVICES)"
	@echo "  staging:    $(STAGING_SERVICES)"
	@echo "  edge:       $(EDGE_SERVICES)"
	@echo "  monitoring: $(MONITORING_SERVICES)"
	@echo "  backup:     $(BACKUP_SERVICES)"

# Especiales — llaman scripts/compose ya existentes, sin reimplementar lógica
staging-up:
	./scripts/staging-up.sh

staging-down:
	./scripts/staging-down.sh

# El "restore" de staging es el ciclo completo (restore + anonimización + up),
# nunca un restore parcial sin anonimizar — honra el invariante de 005.
staging-db-restore: staging-up

backup-backup-run backup:
	$(COMPOSE_BACKUP) exec -T backup /usr/local/bin/backup.sh

setup-backup-role:
	./scripts/setup-backup-role.sh

setup-monitoring-role:
	./scripts/setup-monitoring-role.sh

prod-db-restore:
	./scripts/prod-db-restore.sh

.PHONY: staging-up staging-down staging-db-restore backup-backup-run backup setup-backup-role setup-monitoring-role prod-db-restore

.PHONY: help

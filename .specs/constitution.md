---
name: odoo-infrastructure
version: R03
date: 2026-07-11
---

# Project Constitution

## Purpose

Infraestructura de producción self-hosted para una instancia Odoo 19 Community de un solo cliente (single-tenant), corriendo on-premise en un servidor físico propio (`serverdipleg`). Cubre despliegue con Docker Compose, base de datos, reverse proxy, exposición segura a internet, backups, monitoring, y el pipeline de CI/CD que los mantiene. Basada en los principios de [oec.sh](https://oec.sh) (self-hosted, "bring your own cloud"), adaptados a las restricciones reales de este servidor.

## Tech Stack

- **Orquestación**: Docker Compose, 5 stacks independientes (`prod`, `staging`, `edge`, `monitoring`, `backup`), cada uno en su propio `docker-compose.<stack>.yml`
- **Aplicación**: Odoo 19 Community, imagen propia `FROM odoo:X.Y-YYYYMMDD` (build fechado, no flotante) + addons custom (repos por categoría, agregados en build-time vía `git-aggregator`, pineados por commit/rama en `repos.yaml`) + estructura lista para OCA/Enterprise
- **Base de datos**: PostgreSQL contenedorizado (uno por entorno: prod, staging) + PgBouncer (`transaction pooling`) delante de cada uno
- **Reverse proxy / exposición**: Traefik (ruteo interno por hostname) + Cloudflare Tunnel (`cloudflared`) — sin puertos publicados al host, sin gestión manual de TLS
- **Testing**: suite existente en el repo de addons custom, vía `odoo-bin --test-enable --stop-after-init`
- **Linting / Formatting**: `pylint-odoo`, `flake8`, `black`, `isort` sobre el repo de addons custom
- **CI/CD**: GitHub Actions con runner self-hosted en el propio servidor (sin puertos entrantes, polling saliente)
- **Monitoring**: Prometheus + Grafana + cAdvisor + node-exporter + postgres-exporter, logs centralizados con Loki + Promtail
- **Backups**: contenedor efímero propio (`postgres:16-alpine` + `restic`), destino Cloudflare R2 + copia local — restic provee cifrado en reposo, deduplicación y retención GFS declarativa en una sola herramienta

## Code Principles

- **Ningún contenedor publica puertos al host.** Todo vive en redes internas de Docker; `cloudflared` habla con Traefik por DNS interno, no por `localhost`. (Principio de diseño, no dependiente del estado de ningún servidor previo.)
- **El Makefile es la única interfaz operativa una vez implementada esa feature** (roadmap #6) — compartida entre uso manual y CI, nunca lógica de deploy duplicada entre un script y el YAML del pipeline. Hasta entonces, features individuales pueden operarse con comandos `docker`/`docker compose` directos, según defina su propio spec/plan.
- **Staging es una réplica fiel de prod a menor escala, no un modo de ejecución distinto**: mismo modelo multiproceso (workers, sin `dev_mode`), mismo ruteo de longpolling — solo con menos recursos asignados.
- **Staging es efímera**: se levanta on-demand (máx. ~3h), siempre restaurando el último backup de prod + anonimización antes de levantar Odoo, y se destruye (`down -v`) al terminar. No hay staging "siempre arriba".
- **`list_db = False` y `proxy_mode = True` son no negociables en `odoo.conf`** de cualquier entorno expuesto.
- **Nunca usar el tag `latest`** de ninguna imagen en producción — siempre versión mayor fija con build fechado (`odoo:X.Y-YYYYMMDD`) + tag de build por commit SHA.
- **Deploys a producción son siempre manuales con aprobación**, nunca automáticos; deploys a staging son automáticos tras pasar lint + tests.
- **Todo backup completo = DB + filestore juntos** — uno sin el otro deja el restore incompleto.
- **RAM es el recurso más restrictivo del servidor** (14 GiB compartidos entre todo) — cualquier cambio de sizing (workers, `shared_buffers`, nuevos servicios) debe revisarse contra el presupuesto de RAM documentado, no asumirse aparte.

## Naming Conventions

- Archivos Compose: `docker-compose.<stack>.yml` (`prod`, `staging`, `edge`, `monitoring`, `backup`)
- Targets de Makefile: `<stack>-<service>-<action>` (ej. `prod-odoo-rebuild`, `staging-db-restore`) — sin variables que memorizar
- Imágenes Docker: tag de versión mayor con build fechado (`odoo:X.Y-YYYYMMDD`) + tag de build por commit SHA, nunca `latest`

## Constraints

- Servidor físico único, on-premise (`serverdipleg`): AMD Ryzen 5 5600G, 6 cores/12 threads, 14 GiB RAM, NVMe ~597 GiB libres. Sin servicios gestionados de cloud.
- Sin IP pública fija asumida — toda exposición externa pasa por Cloudflare Tunnel.
- Prod y staging comparten el mismo servidor físico (por costo) — aislados por stacks Compose separados, no por hardware separado.
- Repos de código en GitHub; pipeline en GitHub Actions con runner self-hosted en el mismo servidor.
- Single-tenant: una sola instancia de producción + una de staging. No hay diseño multi-tenant.

## Out of Scope

- Multi-tenant / múltiples clientes en la misma infraestructura (descartado explícitamente).
- Integraciones externas (WhatsApp, Shopify, n8n) — no evaluadas, agregar solo si se pide explícitamente.
- Compliance / residencia de datos regulada — no evaluado; revisar si el negocio lo requiere.
- Cualquier infraestructura Odoo previa/existente en el mismo servidor — este proyecto es independiente y no depende de su estado ni la migra.

## Amendments Log

<!-- Append-only. One line per revision made after this constitution was first approved. Format: - RNN (YYYY-MM-DD): <what changed and why> -->
- R01 (2026-07-10): Hallazgos de `spec-flow:analyze` sobre SPEC-001. Acotado el principio de Makefile a partir de la feature #6 (bloqueaba innecesariamente features previas que operan con `docker`/`docker compose` directo, según su propio spec); `postgres:19-alpine` → `postgres:16-alpine` en Backups (coincidir con la versión de Postgres fijada en PLAN-001, no un copy-paste del major de Odoo); ejemplos de tag de imagen actualizados a `odoo:X.Y-YYYYMMDD` (reflejar la convención de build fechado adoptada en PLAN-001).
- R02 (2026-07-10): Addons custom pasan de "submódulo git separado" a repos por categoría agregados vía `git-aggregator` (pineados por commit/rama en `repos.yaml`) — git submodules resultaron demasiado engorrosos operativamente; `git-aggregator` mantiene el mismo pin de reproducibilidad sin esa fricción, y es la herramienta estándar del ecosistema OCA para este caso exacto.
- R03 (2026-07-11): Backups migran de `rclone` + `gnupg` a `restic` (feature 004-backup-restic) — restic unifica cifrado en reposo, deduplicación, retención GFS declarativa y backend S3/R2 nativo en una sola herramienta, reemplazando `rclone` + `gnupg` + `tar/gzip` + la lógica GFS escrita a mano en bash. La imagen base `postgres:16-alpine` se mantiene (`pg_dump` compatible con la DB).

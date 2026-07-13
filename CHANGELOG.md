# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed
- Reorganización de layout (`007-repo-layout-reorg`) — los 5 `docker-compose.*.yml` y los 2 `Dockerfile*` pasan a vivir bajo `Docker/`, y las 5 plantillas `.env.*.example` (más la convención del `.env.<stack>` real de cada entorno) pasan a `env/`. Cada compose ajusta su `build` (context a la raíz + `dockerfile: Docker/...`), `env_file` (`../env/.env.<stack>`) y mounts (`../config/...`) para seguir resolviendo igual que antes; `config/`, `systemd/`, `scripts/` y `addons/` no se mueven. Toda referencia existente actualizada (scripts, timers de systemd, `INSTALL.md`, `CLAUDE.md`, `docs/infrastructure-design.md`). Deja el terreno listo para el Makefile (roadmap B010), que ya no tendría que tocar estos paths. De paso, se fijó el nombre de proyecto de Compose a `odoo-infrastructure-<stack>` (uno por stack, no un literal idéntico compartido) — un test real durante la implementación reveló que un nombre de proyecto idéntico entre `prod` y `staging` (que comparten nombres de servicio como `db`/`pgbouncer`) hace que Compose recree y reemplace el contenedor del otro stack al levantar el segundo; el sufijo por stack lo evita. Verificado con build real de ambas imágenes desde la nueva ubicación, `docker compose config -q` en las 5 stacks con `env/` real poblado, y un smoke completo del stack `monitoring` exclusivamente con las rutas nuevas.

## [0.6.0] - 2026-07-13

### Added
- Stack `monitoring` (`006-monitoring-stack`) — observabilidad siempre-arriba: Prometheus (+ node-exporter, cAdvisor, postgres-exporter-prod con rol de solo lectura dedicado `pg_monitor`, retención 15d) recolecta métricas de host/contenedores/Postgres; Loki + Promtail (descubrimiento por socket de Docker, retención 15d) centralizan logs de todos los contenedores; Grafana expuesto en `grafana.miempresa.com` por el edge existente, detrás de Cloudflare Access (aprovisionamiento manual, documentado), con datasources y 3 dashboards community pineados (Node Exporter Full, cAdvisor, PostgreSQL) provisionados por config; 3 reglas de Grafana Alerting (RAM host >85%/5m, contenedor esperado caído, Postgres sin conexiones) con contact point SMTP. Ningún puerto publicado al host; imágenes pineadas; sizing revisado contra el presupuesto de RAM. Verificado con smoke real en Docker local (targets de Prometheus, provisioning de Grafana, alertas disparando y enviando email real, router de Traefik con el edge case de backend caído); un bug real corregido (`cadvisor` no registraba el factory de Docker por montar `/var/run` completo en vez del socket). `node-exporter` y el etiquetado por nombre de contenedor de `cadvisor` quedan reservados a validación en el deploy real (limitación del entorno de test, no del código).

## [0.5.0] - 2026-07-12

### Added
- Stack `staging` efímero (`005-staging`) — réplica fiel de prod a menor escala (1 worker, sin `dev_mode`, mismo split de longpolling), en su propia red aislada (`staging-net`; solo Traefik la puentea, staging no alcanza la `db` de prod). Se levanta on-demand restaurando el último backup de prod desde el repo restic local y anonimizándolo **antes** de arrancar Odoo (orden crítico bajo `set -e`: mail servers off, emails/passwords/payment/webhooks/crons neutralizados, atómico vía `psql --single-transaction`), expuesto en `staging.miempresa.com`, con teardown duro auto-forzado a ~3h (timer transiente de systemd + servicio oneshot de boot). `postgres-exporter` vive en el stack de staging (nace/muere con él). Incluye dos correcciones halladas en testing real (`restic restore --no-lock` para repo `:ro`, `chown 100:101` del filestore restaurado). Verificado end-to-end en Docker local; validación de systemd diferida al deploy en Linux real.

### Changed
- `edoburu/pgbouncer` pineado a `1.22.1-p0` en los stacks `prod` y `staging` (antes sin tag = `latest` implícito) — reproducibilidad.

## [0.4.0] - 2026-07-12

### Changed
- Stack `backup` migrado a `restic` (`004-backup-restic`) — reemplaza `rclone` + `gnupg` + `tar/gzip` + la lógica GFS escrita a mano en bash por `restic`, que unifica cifrado en reposo (AES-256), deduplicación, retención GFS declarativa y backend S3/R2 nativo en una sola herramienta. Snapshot único DB (`pg_dump -Fp`) + filestore; repo local (14 diarias) + repo R2 (14d/4w/12m/3y) poblado por `restic copy` (una sola lectura/chunkeo del filestore). Corrige un bug de locks huérfanos (`restic unlock --remove-all`, seguro por el invariante single-writer del timer) y reconcilia el sizing 512m→1g contra el presupuesto de RAM. Enmienda de constitución R03. Verificado de punta a punta en Docker local (dedupe, restore round-trip DB+filestore, rechazo de passphrase).

## [0.3.0] - 2026-07-11

### Added
- Stack `backup` (`003-backup-stack`) — contenedor efímero (`postgres:16-alpine` + `rclone` + `gnupg`, versiones pineadas) que respalda DB (rol de Postgres dedicado, solo lectura) + filestore juntos, cifra con GPG simétrico antes de tocar cualquier destino, sube a `daily/weekly/monthly` con retención GFS manejada por el propio script (30d/3 meses/1 año) más copia local de 7 días, disparado por timer de `systemd` versionado. Verificado de punta a punta en Docker local y en `serverdipleg` (hardware real).

## [0.2.0] - 2026-07-10

### Added
- Stack `edge` (`002-edge-stack`) — Traefik + Cloudflare Tunnel sobre una red Docker externa compartida con `prod`, ruteo por hostname vía config estática (sin socket de Docker), split `/websocket`→8072 con prioridad explícita (verificado con handshake real, `101 Switching Protocols`), límites de tamaño de request y timeouts largos, sizing aplicado. Elimina el mapeo de puerto temporal de la feature 1.

## [0.1.1] - 2026-07-10

### Added
- Imagen Docker + stack de producción (`001-imagen-docker-prod`) — `Dockerfile` multi-stage (`git-aggregator` agrega los addons custom por categoría, pineados por commit/rama), `docker-compose.prod.yml` (Odoo + Postgres + PgBouncer) con sizing, healthchecks y límites de recursos aplicados, sin puertos publicados al host por defecto.

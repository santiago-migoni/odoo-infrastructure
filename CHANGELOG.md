# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

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

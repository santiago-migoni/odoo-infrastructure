# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- Stack `backup` (`003-backup-stack`) — contenedor efímero (`postgres:16-alpine` + `rclone` + `gnupg`, versiones pineadas) que respalda DB (rol de Postgres dedicado, solo lectura) + filestore juntos, cifra con GPG simétrico antes de tocar cualquier destino, sube a `daily/weekly/monthly` con retención GFS manejada por el propio script (30d/3 meses/1 año) más copia local de 7 días, disparado por timer de `systemd` versionado. Verificado de punta a punta en Docker local y en `serverdipleg` (hardware real).

## [0.2.0] - 2026-07-10

### Added
- Stack `edge` (`002-edge-stack`) — Traefik + Cloudflare Tunnel sobre una red Docker externa compartida con `prod`, ruteo por hostname vía config estática (sin socket de Docker), split `/websocket`→8072 con prioridad explícita (verificado con handshake real, `101 Switching Protocols`), límites de tamaño de request y timeouts largos, sizing aplicado. Elimina el mapeo de puerto temporal de la feature 1.

## [0.1.1] - 2026-07-10

### Added
- Imagen Docker + stack de producción (`001-imagen-docker-prod`) — `Dockerfile` multi-stage (`git-aggregator` agrega los addons custom por categoría, pineados por commit/rama), `docker-compose.prod.yml` (Odoo + Postgres + PgBouncer) con sizing, healthchecks y límites de recursos aplicados, sin puertos publicados al host por defecto.

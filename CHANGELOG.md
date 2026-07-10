# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

## [0.1.1] - 2026-07-10

### Added
- Imagen Docker + stack de producción (`001-imagen-docker-prod`) — `Dockerfile` multi-stage (`git-aggregator` agrega los addons custom por categoría, pineados por commit/rama), `docker-compose.prod.yml` (Odoo + Postgres + PgBouncer) con sizing, healthchecks y límites de recursos aplicados, sin puertos publicados al host por defecto.

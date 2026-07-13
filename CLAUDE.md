# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Self-hosted Odoo 19 Community infrastructure for a single-tenant deployment on `serverdipleg` (AMD Ryzen 5 5600G, 6 cores/12 threads, 14 GiB RAM, NVMe). Full design in `docs/infrastructure-design.md`. Constitution in `.specs/constitution.md`.

## Operational Rules

- **Never SSH into `serverdipleg`** to mutate files, permissions, or containers directly. Fix root cause in the repo.
- **Never run `git commit`, `git push`, `git tag`, or `gh release`**. Always hand the user the exact commands to run.

## Common Commands

The Makefile is the single operational interface — shared between manual use and CI. Naming: `<stack>-<service>-<action>`.

```bash
# Stack lifecycle
make prod-up                  # docker/docker-compose.prod.yml up -d (all services)
make prod-odoo-rebuild        # build --no-cache + up -d odoo
make prod-odoo-logs           # logs -f odoo

make staging-up               # restore last prod backup + anonymize + up (max 3h, then auto down -v)
make staging-down             # down -v (destroys staging volumes)

make edge-traefik-restart
make monitoring-grafana-up
make backup-backup-run        # ephemeral run --rm; also triggered by systemd timer daily

# Prod DB restore — destructive, requires explicit confirmation
make prod-db-restore CONFIRM=yes
```

Lint and tests run on the **addons custom repo** (separate git submodule under `addons/`):

```bash
black --check addons/
isort --check addons/
flake8 addons/
pylint-odoo addons/
odoo-bin -d test_db --test-enable --stop-after-init -i <module>
```

## Architecture

### 5 Docker Compose Stacks

| Stack | File | Services |
|---|---|---|
| `prod` | `docker/docker-compose.prod.yml` | `odoo`, `db`, `pgbouncer` |
| `staging` | `docker/docker-compose.staging.yml` | `odoo`, `db`, `pgbouncer`, `postgres-exporter` |
| `edge` | `docker/docker-compose.edge.yml` | `traefik`, `cloudflared` |
| `monitoring` | `docker/docker-compose.monitoring.yml` | `prometheus`, `grafana`, `loki`, `promtail`, `cadvisor`, `node-exporter`, `postgres-exporter-prod` |
| `backup` | `docker/docker-compose.backup.yml` | `backup` (ephemeral, `run --rm`) |

All stacks share a single Docker internal network. **No container publishes ports to the host.** `cloudflared` talks to Traefik via Docker DNS (`http://traefik:80`).

### Traffic Flow

Internet → Cloudflare Edge (TLS terminated) → `cloudflared` container → Traefik (routes by hostname) → Odoo containers.

Traefik defines **two routers per Odoo instance**: `/websocket` → port 8072 (gevent/longpolling), everything else → port 8069.

### Odoo Image

`FROM odoo:19.0` — custom `docker/Dockerfile` copies `addons/` submodule, installs extra Python requirements. Tagged by commit SHA (never `latest`). Runs as `odoo` user (UID 101, never root).

### Staging Is Ephemeral

Every `make staging-up` restores the latest prod backup and runs the anonymization SQL **before** starting Odoo (order is critical — Odoo must not start with unanonymized prod data). Staging auto-tears down after ~3h (`down -v`). `postgres-exporter` lives in `docker/docker-compose.staging.yml`, not in the monitoring stack, so it starts/stops with staging.

### Backup

Ephemeral container (`postgres:19-alpine` + `rclone` + `gnupg`). Always DB (`pg_dump -Fc`) + filestore (`tar/gzip`) together — one without the other is incomplete. Encrypted with GPG before upload. Destinations: Cloudflare R2 (GFS retention: 30 daily / 3-month weekly / 1-year monthly) + local last-7-days copy.

### Secrets

- **Pipeline**: GitHub Actions Secrets.
- **Runtime**: `.env` per environment on the server, outside the repo (`chmod 600`), referenced via `env_file` in Compose files.

## Non-Negotiable Constraints

- `list_db = False` and `proxy_mode = True` in every `odoo.conf` for any exposed environment.
- Never use `latest` image tag — always `odoo:19.0` + commit SHA build tag.
- Prod deploys are always manual with approval; staging deploys are automatic after lint + tests pass.
- Any sizing change (workers, `shared_buffers`, new services) must be reviewed against the RAM budget in `docs/infrastructure-design.md`. RAM is the real bottleneck (14 GiB shared between all stacks).
- `PGDATA` must point to a subdirectory of the volume (`/var/lib/postgresql/data/pgdata`), not the mount point root.
- `odoo.conf` is always mounted read-only (`:ro`).

## RAM Budget (summary)

| Scenario | Estimated total |
|---|---|
| Baseline (staging down) | ~11.0 GiB |
| Peak (staging active, 3h window) | ~13.1 GiB |

Prod: 3 Odoo workers (`limit_memory_hard=2048 MiB`), Postgres `shared_buffers=1.5 GiB`.  
Staging: 1 worker (`hard=682 MiB`), Postgres `shared_buffers=512 MiB`. No `dev_mode`.

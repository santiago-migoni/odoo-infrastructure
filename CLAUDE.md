# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Self-hosted Odoo 19 Community infrastructure for a single-tenant deployment on `serverdipleg` (AMD Ryzen 5 5600G, 6 cores/12 threads, 14 GiB RAM, NVMe). Constitution in `.specs/constitution.md`. Design history and rationale per feature in `.specs/archive/`.

## Operational Rules

- **Never SSH into `serverdipleg`** to mutate files, permissions, or containers directly. Fix root cause in the repo.
- **Never run `git commit`, `git push`, `git tag`, or `gh release`**. Always hand the user the exact commands to run.

## Common Commands

The Makefile is the single operational interface for manual use — a single dispatcher script (`scripts/mk-dispatch.sh`) is the source of truth for validation/menus/guided errors. Naming: `<verb>-<stack>[-<service>]` (verb first, optional service always last). Type a bare verb (`make down`) to see valid combinations; `make help` lists everything.

```bash
# Stack lifecycle
make up-prod                  # prod/docker/docker-compose.yml up -d (all services)
make rebuild-prod-odoo        # build --no-cache + up -d odoo
make logs-prod-odoo           # logs -f odoo

make refresh-staging          # restore last prod backup + anonymize + up (always-on, weekly auto-refresh)
make nuke-staging              # down -v (destroys staging volumes)

make restart-edge-traefik
make up-monitoring-grafana
make run-backup                # runs inside the always-up backup container; also triggered by systemd timer daily

# Prod DB restore — destructive, requires explicit confirmation
make restore-prod CONFIRM=yes
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

Each stack is self-contained in its own top-level folder (`<stack>/docker/`, `<stack>/config/`, `<stack>/env/` — feature `013-stack-layout-reorg`), not grouped by artifact type.

| Stack        | File                                   | Services                                                                                          |
|---           |---                                     |---                                                                                                |
| `prod`       | `prod/docker/docker-compose.yml`       | `odoo`, `db`, `pgbouncer`                                                                         |
| `staging`    | `staging/docker/docker-compose.yml`    | `odoo`, `db`, `pgbouncer`, `postgres-exporter`                                                    |
| `edge`       | `edge/docker/docker-compose.yml`       | `traefik`, `cloudflared`                                                                          |
| `monitoring` | `monitoring/docker/docker-compose.yml` | `prometheus`, `grafana`, `loki`, `promtail`, `cadvisor`, `node-exporter` `postgres-exporter-prod` |
| `backup`     | `backup/docker/docker-compose.yml`     | `backup` (ephemeral, `run --rm`)                                                                  |

All stacks share a single Docker internal network. **No container publishes ports to the host.** `cloudflared` talks to Traefik via Docker DNS (`http://traefik:80`).

### Traffic Flow

Internet → Cloudflare Edge (TLS terminated) → `cloudflared` container → Traefik (routes by hostname) → Odoo containers.

Traefik defines **two routers per Odoo instance**: `/websocket` → port 8072 (gevent/longpolling), everything else → port 8069.

### Odoo Image

`FROM odoo:19.0` — `prod` and `staging` each have their own independent `Dockerfile` (`prod/docker/Dockerfile`, `staging/docker/Dockerfile`, never shared) that copies `addons/`, installs extra Python requirements. Same content on day one, free to diverge afterward — promoting a staging-validated change to prod is an explicit code change (PR porting the diff), never automatic. Tagged by commit SHA (never `latest`). Runs as `odoo` user (UID 101, never root).

### Staging Is Always-On, Weekly Refresh

Every `make refresh-staging` restores the latest prod backup and runs the anonymization SQL **before** starting Odoo (order is critical — Odoo must not start with unanonymized prod data). Staging stays up permanently (`restart: unless-stopped`, survives a server reboot) and refreshes automatically once a week via a systemd timer running this same cycle — no auto-teardown. `postgres-exporter` lives in `staging/docker/docker-compose.yml`, not in the monitoring stack, so it starts/stops with staging.

### Backup

Ephemeral container (`postgres:19-alpine` + `rclone` + `gnupg`). Always DB (`pg_dump -Fc`) + filestore (`tar/gzip`) together — one without the other is incomplete. Encrypted with GPG before upload. Destinations: Cloudflare R2 (GFS retention: 30 daily / 3-month weekly / 1-year monthly) + local last-7-days copy.

### Secrets

- **Pipeline**: GitHub Actions Secrets.
- **Runtime**: `.env` per environment on the server, outside the repo (`chmod 600`), referenced via `env_file` in Compose files.

## Non-Negotiable Constraints

- `list_db = False` and `proxy_mode = True` in every `odoo.conf` for any exposed environment.
- Never use `latest` image tag — always `odoo:19.0` + commit SHA build tag.
- Prod deploys are always manual with approval; staging deploys are automatic after lint + tests pass.
- Any sizing change (workers, `shared_buffers`, new services) must be reviewed against the RAM budget below. RAM is the real bottleneck (14 GiB shared between all stacks).
- `PGDATA` must point to a subdirectory of the volume (`/var/lib/postgresql/data/pgdata`), not the mount point root.
- `odoo.conf` is always mounted read-only (`:ro`).

## RAM Budget (summary)

| Scenario                         | Estimated total                          |
|---                               |---                                       |
| Baseline (staging down)          | ~11.0 GiB                                |
| Peak (staging active)            | ~13.1 GiB                                |

Prod: 3 Odoo workers (`limit_memory_hard=2048 MiB`), Postgres `shared_buffers=1.5 GiB`.  
Staging: 1 worker (`hard=682 MiB`), Postgres `shared_buffers=512 MiB`. No `dev_mode`.

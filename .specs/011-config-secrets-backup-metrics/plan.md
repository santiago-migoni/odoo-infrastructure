---
name: config-secrets-backup-metrics
code: PLAN-011
version: R00
date: 2026-07-14
---

# Plan: Config Secrets Out of Git + Backup Freshness as a Prometheus Metric

## Approach

US1 reuses the exact `.example` + gitignored-real pattern already in place for `env/.env.*`, and validates `list_db`/`proxy_mode` by loading the config through Odoo's own `odoo.tools.config` parser (not a hand-rolled ini/grep check) inside a thin wrapper `ENTRYPOINT` — kept in `scripts/`, alongside the repo's other operational shell scripts (`backup.sh`, `restore-*.sh`, etc.) — that runs before handing off to the base image's original `/entrypoint.sh`. US2 reuses node-exporter's built-in textfile collector — `backup.sh` writes a one-line `.prom` gauge (atomically) to a new bind-mounted directory shared read-write with the backup container and read-only with node-exporter — no new service, no new dependency.

## Constitution Check

- **Tech stack**: No new services or images. Reuses `node-exporter` (already in `monitoring`) and the Odoo image's own Python/`odoo.tools` (already in `prod`/`staging`). Aligned.
- **Code principles**: "RAM es el recurso más restrictivo" — zero new containers, zero RAM delta. "`list_db=False`/`proxy_mode=True` no negociables" — this plan is exactly that principle made self-enforcing at boot instead of only documented.
- **Constraints**: Single physical server, no managed cloud services — the textfile collector directory is a plain host bind mount (`/srv/...`), same pattern as `/srv/odoo-backups`. No conflicts.

## Architecture

**US1 — config secrets:**
`config/odoo.conf` and `config/odoo-staging.conf` stop being tracked by git (`git rm --cached` + `.gitignore` entries) and are replaced in the repo by `config/odoo.conf.example` / `config/odoo-staging.conf.example` (current content, versioned as reference). The real files keep living on disk untouched — server behavior doesn't change, only git's view of them.

A new `scripts/odoo-entrypoint.sh` becomes the image's `ENTRYPOINT`. It loads `$ODOO_RC` through `odoo.tools.config.parse_config()` — the same loader Odoo itself uses at boot, so it sees the effective config (not a raw-text grep) — asserts `list_db is False` and `proxy_mode is True`, and `exec`s the original base-image `/entrypoint.sh "$@"` only if both hold. A failed assertion raises `SystemExit`, the script exits non-zero, and Docker never reaches `exec odoo` — the container exits instead of starting unhealthy.

**US2 — backup freshness metric:**
A new host directory (e.g. `/srv/node-exporter-textfile`) is bind-mounted read-write into the `backup` container and read-only into `node-exporter` (`--collector.textfile.directory` flag added to its existing `command:`). After `touch /backups/.last-success` — the last step of `backup.sh`, only reached on full success — the script writes `odoo_backup_last_success_timestamp_seconds <unix ts>` to a temp file in that directory and `mv`s it into place (atomic rename, same filesystem — node-exporter never observes a partial write). The metric is a timestamp, not a precomputed age, so Prometheus computes freshness at query/alert time (`time() - odoo_backup_last_success_timestamp_seconds`) and the value never "goes stale" on its own. If backup never succeeded, the file simply doesn't exist and the metric is absent (queryable via `absent()`), distinguishable from an old-but-present timestamp.

## File Structure

```text
config/
├── odoo.conf.example            ← new, versioned copy of current odoo.conf
├── odoo-staging.conf.example    ← new, versioned copy of current odoo-staging.conf
├── odoo.conf                    ← untracked (git rm --cached), stays on disk as-is
└── odoo-staging.conf            ← untracked (git rm --cached), stays on disk as-is

docker/
├── Dockerfile                    ← modified: COPY scripts/odoo-entrypoint.sh, ENTRYPOINT
├── docker-compose.backup.yml     ← modified: new bind mount for textfile dir
└── docker-compose.monitoring.yml ← modified: node-exporter gets textfile dir mount + flag

scripts/
├── odoo-entrypoint.sh             ← new, config check + exec original entrypoint
└── backup.sh                      ← modified: write .prom metric after .last-success

.gitignore                        ← modified: add config/odoo.conf, config/odoo-staging.conf

INSTALL.md                        ← modified: setup step for config/*.conf from .example,
                                     mkdir -p /srv/node-exporter-textfile
```

## Data Model

N/A

## API / Interface Contracts

- **Entrypoint contract**: `scripts/odoo-entrypoint.sh` receives the same argv Docker would otherwise pass to `/entrypoint.sh` (i.e. the compose `command`, defaulting to `odoo`) and forwards it unchanged via `exec /entrypoint.sh "$@"` after the check passes. Exit code non-zero and no forwarding on failure.
- **Metric contract**: `odoo_backup_last_success_timestamp_seconds` (gauge, no labels) — Unix timestamp of the last successful backup, written to `<textfile-dir>/odoo_backup.prom`. Standard node-exporter textfile collector format (`# TYPE` line + one sample line).

## Dependencies

None — existing dependencies suffice (`odoo.tools.config` ships with the Odoo image; node-exporter's textfile collector is a built-in flag, no plugin).

## Risks & Unknowns

- The base image's `/entrypoint.sh` path and `$ODOO_RC` default (`/etc/odoo/odoo.conf`) were confirmed against the exact pinned tag (`odoo:19.0-20260630`) used in `docker/Dockerfile` — if that base tag is ever bumped, re-verify both haven't moved before trusting the wrapper silently.
- `git rm --cached` on `config/odoo.conf`/`config/odoo-staging.conf` only stops future tracking; existing git history still contains past contents of these files. Out of scope per spec (no history rewrite requested), but worth flagging once during implementation review.

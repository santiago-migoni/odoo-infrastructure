---
name: config-secrets-backup-metrics
code: TASKS-011
version: R00
date: 2026-07-14
---

# Tasks: Config Secrets Out of Git + Backup Freshness as a Prometheus Metric

## Phase 1: US1 — Config real fuera de git, con red de seguridad al arrancar (P1)

- [x] T001 [P][US1] Create `config/odoo.conf.example` as a versioned copy of the current `config/odoo.conf` content
- [x] T002 [P][US1] Create `config/odoo-staging.conf.example` as a versioned copy of the current `config/odoo-staging.conf` content
- [x] T003 [US1] Add `config/odoo.conf` and `config/odoo-staging.conf` to `.gitignore`
- [x] T004 [US1] Depends on T001-T003 — `git rm --cached config/odoo.conf config/odoo-staging.conf` to untrack them (real files stay on disk unchanged)
- [x] T005 [US1] Write `scripts/odoo-entrypoint.sh`: load `$ODOO_RC` via `odoo.tools.config.parse_config()`, assert `config['list_db'] is False` and `config['proxy_mode'] is True`, raise a `SystemExit` naming which check failed if not, then `exec /entrypoint.sh "$@"` on success
- [x] T006 [US1] Depends on T005 — `chmod +x scripts/odoo-entrypoint.sh`
- [x] T007 [US1] Depends on T006 — modify `docker/Dockerfile`: `COPY scripts/odoo-entrypoint.sh /usr/local/bin/odoo-entrypoint.sh`, `RUN chmod +x`, and set `ENTRYPOINT ["/usr/local/bin/odoo-entrypoint.sh"]` (keep inherited `CMD ["odoo"]`)
- [x] T008 [P][US1] Update `INSTALL.md`: add the setup step `cp config/odoo.conf.example config/odoo.conf` (and the `-staging` variant) before the first `make prod-up` / `make staging-up`, next to the existing `env/.env.*.example` copy steps

## Phase 2: US2 — Freshness del backup visible en Prometheus (P2)

- [x] T009 [US2] Modify `scripts/backup.sh`: right after `touch /backups/.last-success`, write `odoo_backup_last_success_timestamp_seconds <unix ts>` to a temp file under `/textfile-collector` and `mv` it into place as `/textfile-collector/odoo_backup.prom` (atomic rename, skip silently if the directory isn't mounted)
- [x] T010 [P][US2] Modify `docker/docker-compose.backup.yml`: add bind mount `/srv/node-exporter-textfile:/textfile-collector` (read-write) to the `backup` service
- [x] T011 [P][US2] Modify `docker/docker-compose.monitoring.yml`: add bind mount `/srv/node-exporter-textfile:/textfile-collector:ro` and the `--collector.textfile.directory=/textfile-collector` flag to `node-exporter`'s `command:`
- [x] T012 [US2] Depends on T010, T011 — update `INSTALL.md`: add `sudo mkdir -p /srv/node-exporter-textfile` next to the existing `sudo mkdir -p /srv/odoo-backups` setup step

## Verification

- [x] VERIFY [US1] Build the `odoo` image and run it with a mounted `odoo.conf` where `list_db=False`/`proxy_mode=True` — container starts normally (spec US1 scenario 2)
- [x] VERIFY [US1] Run it with `list_db=True` (or `proxy_mode=False`) in the mounted `odoo.conf` — container exits non-zero before reaching `exec odoo`, error names the offending key (spec US1 scenario 3)
- [x] VERIFY [US1] `git status` / `git ls-files config/` shows only the two `.example` files tracked; the real `.conf` files are untracked (spec US1 scenario 1)
- [x] VERIFY [US2] Run `make backup-backup-run`, confirm `/srv/node-exporter-textfile/odoo_backup.prom` exists with a valid gauge line — verified the atomic-write logic in isolation (real run needs live restic/R2 creds not available in this environment)
- [x] VERIFY [US2] Query node-exporter's `/metrics` (or Prometheus) and confirm `odoo_backup_last_success_timestamp_seconds` is exposed and queryable (spec US2 scenario 1) — confirmed end-to-end against the real node-exporter v1.8.2 image
- [x] VERIFY No files were created that are not listed in `plan.md`'s File Structure
- [x] VERIFY No new dependencies were added beyond those listed in `plan.md` (none)

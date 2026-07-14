---
name: staging
code: TASKS-005
version: R01
date: 2026-07-12
---

# Tasks: Stack `staging` efímero

## Phase 1: Setup

- [x] T001 [setup][US5] Escribir `docker-compose.staging.yml`: servicios `db` (`postgres:16-alpine`, `shared_buffers=512MB`, `PGDATA` en subdirectorio, `POSTGRES_DB=odoo_staging` vía `.env.staging` — la base la crea vacía el init del contenedor para que el restore la cargue), `pgbouncer` (`edoburu/pgbouncer`, transaction pooling), `odoo` (imagen propia, alias de red `odoo-staging`, `odoo-staging.conf` `:ro`), `postgres-exporter` (`quay.io/prometheuscommunity/postgres-exporter`, versión pineada); red `staging-net` (externa); volúmenes `db-data-staging`/`odoo-data-staging` **no externos** (se destruyen con `down -v`); `mem_limit`/`cpus` por servicio
- [x] T002 [P][setup][US2] Escribir `config/odoo-staging.conf`: igual estructura que `config/odoo.conf` pero `db_name=odoo_staging`, `workers=1`, `max_cron_threads=1`, `limit_memory_soft=572522496`, `limit_memory_hard=715128832`, `list_db=False`, `proxy_mode=True`, sin `dev_mode`, mismo `addons_path`
- [x] T003 [P][setup] Escribir `.env.staging.example`: credenciales de `db`/`pgbouncer` staging (POSTGRES_*/DB_*/USER/PASSWORD), `RESTIC_PASSWORD` + `RESTIC_REPOSITORY_LOCAL` para el restore, DSN de `postgres-exporter` — todos placeholders; `.env.staging` real ya gitignored

## Phase 2: Teardown duro (US4)

- [x] T004 [US4] Escribir `scripts/staging-down.sh`: `docker compose -f docker-compose.staging.yml down -v` + cancelar el timer transiente (`systemctl stop odoo-staging-teardown.timer` best-effort)
- [x] T005 [US4] Escribir `scripts/staging-extend.sh`: parar el timer si existe y re-armarlo con `systemd-run --on-active=3h --unit=odoo-staging-teardown` apuntando a `staging-down.sh` (~3h más)
- [x] T006 [US4] Escribir `systemd/staging-teardown-boot.service`: oneshot, `After=docker.service`, `WantedBy=multi-user.target`, `ExecStart=docker compose -f docker-compose.staging.yml down -v` (no-op si staging no está arriba)

## Phase 3: Restore + anonimización + orquestación (US1)

- [x] T007 [US1] Escribir `scripts/restore-staging.sh` (corre en la imagen `Dockerfile.backup` vía `--entrypoint`): `restic restore latest` del repo local → `psql` carga el `db.sql` en la base `odoo_staging` ya existente (creada por el init del contenedor, T001), conectando **directo a `db:5432`, no a pgbouncer:6432** (el transaction pooling rompe operaciones a nivel sesión durante el load del dump) → copia el filestore restaurado de `filestore/odoo/` a `filestore/odoo_staging/` (rename por `db_name` distinto)
- [x] T008 [P][US1] Escribir `scripts/anonymize-staging.sql` (atomicidad todo-o-nada la da `psql --single-transaction` en T009, no `BEGIN`/`COMMIT` propio — evita una transacción anidada redundante): `UPDATE ir_mail_server SET active=false`; passwords de `res_users` a valores random; `UPDATE res_partner SET email='staging+'||id||'@example.com'`; deshabilitar payment providers; limpiar URLs de webhooks en `ir_config_parameter`; desactivar crons de mail
- [x] T009 [US1] Escribir `scripts/staging-up.sh` (bajo `set -e`, orden crítico): si staging ya activa → `staging-down.sh` (teardown+fresh); `up -d db` (solo db); correr `restore-staging.sh` (directo a `db:5432`); correr `anonymize-staging.sql` con `psql -v ON_ERROR_STOP=1 --single-transaction` directo a `db:5432` (un fallo de cualquier statement sale ≠0 y `set -e` aborta antes de levantar Odoo — sin `ON_ERROR_STOP` psql sale 0 aunque falle un UPDATE y Odoo arrancaría sobre datos a medio anonimizar); **recién ahí** `up -d pgbouncer odoo postgres-exporter`; armar el timer de teardown vía `staging-extend.sh`

## Phase 4: Exposición por el edge (US3)

- [x] T010 [US2][US3] Modificar `config/traefik-dynamic.yml`: agregar routers `odoo-staging-ws` (priority 100, `Host(staging.miempresa.com) && PathPrefix(/websocket)` → `http://odoo-staging:8072`) y `odoo-staging` (priority 1, `Host(staging.miempresa.com)` → `http://odoo-staging:8069`), ambos con el middleware `odoo-buffering` existente; agregar los services correspondientes
- [x] T011 [US3] Modificar `docker-compose.edge.yml`: agregar `staging-net` (external) a las redes del servicio `traefik` (queda en `odoo-shared` + `staging-net`)

## Phase 5: Documentación

- [x] T012 [setup] Actualizar `INSTALL.md`: bootstrap de `staging-net` (`docker network create staging-net`), ruta de Tunnel para `staging.miempresa.com`, ciclo `staging-up`/`staging-extend`/`staging-down`, instalación del `staging-teardown-boot.service` (`systemctl enable`)

## Verification

- [x] VERIFY US1 — Confirmado con smoke real (Postgres 16 throwaway + schema mínimo de las tablas que toca la anonimización, empaquetado como snapshot restic real vía la imagen `Dockerfile.backup`). Restore cargó el dump y el filestore renombrado (`odoo/`→`odoo_staging/`) correctamente. **Atomicidad confirmada con un fallo real**: un SQL con un statement roto salió `exit 3` y el estado quedó 100% sin anonimizar (rollback completo, `ON_ERROR_STOP` + `--single-transaction`) — ningún dato a medias. Anonimización real confirmada en las 5 dimensiones: `ir_mail_server` inactivos (0 activos), emails reescritos a `staging+id@example.com` (0 reales), payment providers `disabled` (0 enabled), `ir_config_parameter` de webhooks eliminados (0 restantes), `ir_cron` de `mail.mail` desactivado (0 activos con ese model_id) — y confirmado que el filtro NO toca cron de modelos no listados (`res.partner` no se tocó). **Bug real encontrado y corregido**: `restic restore` necesita escribir un lock incluso en modo lectura — con el repo montado `:ro` colgaba reintentando indefinidamente; corregido con `restic restore --no-lock` en `restore-staging.sh`. **Segundo bug real encontrado y corregido**: el filestore restaurado quedaba con ownership `root` (el contenedor de restore corre como root), y Odoo (UID 100/GID 101, confirmado con `id odoo` — no 101 como decía CLAUDE.md) no podía ni crear `.local/share/Odoo/sessions/` (`PermissionError` real en los logs); corregido con `chown -R 100:101` al final de `restore-staging.sh`.
- [x] VERIFY US2 — `odoo-staging.conf` confirmado con `workers=1`, `db_name=odoo_staging` (el dump cargó ahí y Odoo conectó a esa base, visible en sus logs), `list_db=False`/`proxy_mode=True` presentes. **Split de longpolling confirmado por firma HTTP real** (mismo método que en la feature 002): `/web/health` responde con header `Server: Werkzeug/3.0.1` (puerto 8069), `/websocket` responde sin ese header (puerto 8072) — confirma que los dos routers de Traefik efectivamente separan por puerto, no que ambos caen al mismo backend por coincidencia.
- [x] VERIFY US3 — Confirmado con Traefik real + routers de `traefik-dynamic.yml`: `Host: staging.miempresa.com` contra la IP de Traefik en `staging-net` rutea correctamente (500 real de Odoo, no 000 de conexión fallida) tanto en `/web/health` como `/websocket`. Con `odoo-staging` parado, Traefik responde `502` (servicio no disponible) y el propio Traefik sigue `running` — no crashea. **Aislamiento de red confirmado estructuralmente**: `docker inspect` muestra `odoo-staging` únicamente en `staging-net` (nunca en `odoo-shared`) y `traefik` en ambas — la membresía de red de Docker garantiza que `odoo-staging` no puede alcanzar nada que viva solo en `odoo-shared` (como la `db` de prod). El hop `cloudflared→Traefik` no se probó (requiere un Tunnel real de Cloudflare, igual que en las features 002/004 — reservado para el despliegue real).
- [x] VERIFY US4 — `down -v` confirmado: destruye `db-data-staging` y `odoo-data-staging` limpiamente (probado real). **Parte de systemd diferida a deploy** (decisión explícita al cerrar la branch): `systemd-run`/`staging-extend.sh`/`staging-teardown-boot.service` no se pueden correr en macOS; su validación (`systemd-analyze verify` + ciclo real de armado/extensión/boot) queda como paso de deploy en `serverdipleg` (Linux real), ya documentado en el paso 6 de `INSTALL.md`. Mismo patrón que el timer de backup en la feature 003.
- [x] VERIFY US5 — Confirmado con smoke real: `postgres-exporter` scrapeó la `db` de staging y expuso **672 métricas `pg_*` reales** (no solo "está definido en el compose"). Al hacer `down -v`, el contenedor se destruye junto con el resto del stack — no queda como target huérfano.
- [x] VERIFY Edge case — Confirmado: `restic restore` contra un repo inexistente sale `exit 10` (≠0) — bajo `set -e` en `staging-up.sh`, esto aborta antes de la anonimización o de levantar Odoo.
- [x] VERIFY No se crearon archivos fuera de los listados en "File Structure" de `plan.md` — confirmado con `git status`.
- [x] VERIFY No se agregaron dependencias fuera de la imagen `postgres-exporter` pineada (única nueva, `quay.io/prometheuscommunity/postgres-exporter:v0.15.0`, confirmada disponible vía `docker manifest inspect`); resto reutiliza imágenes ya en uso.

## Phase 6: Convergence

- [x] T013 Pinear `edoburu/pgbouncer` a una versión concreta en `docker-compose.staging.yml` **y** `docker-compose.prod.yml` — hoy sin tag = `latest` implícito, rompe reproducibilidad y la "réplica fiel de prod" (Constitución, Naming Conventions "nunca latest"). Fixear ambos para no dejarlos inconsistentes (contradicts). **Aplicado**: ambos pineados a `edoburu/pgbouncer:1.22.1-p0` (confirmada disponible vía `docker manifest inspect`, la más reciente); `docker compose config -q` pasa en los dos
- [x] T014 Actualizar la tabla de RAM en `docs/infrastructure-design.md`: filas de staging (`odoo`, `db`, `pgbouncer`, `postgres-exporter`) de "diseño, no implementado" a implementado con sus `mem_limit` reales (`db 1.5g`, `odoo-staging 2g`, `pgbouncer 128m`, `exporter 64m`), reconciliadas contra el presupuesto (Constitución MUST: sizing revisado contra el presupuesto de RAM) (partial). **Aplicado**: 4 filas actualizadas a "implementado (005)" con sus techos; reconciliado — los `mem_limit` son techos, el peak presupuestado usa el consumo Normal estimado (sin cambios), así que el margen del peak se mantiene

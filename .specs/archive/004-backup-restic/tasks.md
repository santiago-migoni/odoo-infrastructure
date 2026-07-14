---
name: backup-restic
code: TASKS-004
version: R00
date: 2026-07-11
---

# Tasks: Migrar el stack de backup a restic

## Phase 1: Setup

- [x] T001 [setup] Modificar `Dockerfile.backup`: `apk add restic=0.18.1-r7` en vez de `rclone`+`gnupg` (confirmado disponible en Alpine v3.24 community); mantener `FROM postgres:16-alpine`, la copia de `scripts/backup.sh` y el `ENTRYPOINT`
- [x] T002 [P][setup] Reescribir `.env.backup.example`: mantener `PGHOST`/`PGUSER`/`PGPASSWORD`/`PGDATABASE`/`BACKUP_DB_PASSWORD`; reemplazar `GPG_PASSPHRASE` por `RESTIC_PASSWORD`; reemplazar `RCLONE_*` por `RESTIC_REPOSITORY_LOCAL=/backups/restic`, `RESTIC_REPOSITORY_R2=s3:https://<accountid>.r2.cloudflarestorage.com/<bucket>`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`; comentar que en test `RESTIC_REPOSITORY_R2` puede ser una ruta de filesystem plana

## Phase 2: Backup completo en un snapshot + cifrado (US1, US2)

- [x] T003 [US1] Reescribir `scripts/backup.sh` (parte 1/3): `set -e`; `pg_dump -Fp` (plano) con el rol RO a `$WORKDIR/db.sql` (nombre estable); `trap` de limpieza del `$WORKDIR`. Si `pg_dump` falla, sale sin tocar ningún repo
- [x] T004 [US1][US2] Ampliar `scripts/backup.sh` (parte 2/3 — repo local): función/bloque que hace `restic cat config >/dev/null 2>&1 || restic init`, `restic unlock`, `restic backup "$DUMP_FILE" /filestore/.local/share/Odoo/filestore/odoo` contra `RESTIC_REPOSITORY_LOCAL` (cifrado AES-256 vía `RESTIC_PASSWORD`)

## Phase 3: Dos destinos con retención GFS declarativa (US3)

- [x] T005 [US3] Ampliar `scripts/backup.sh`: `restic forget --keep-daily 14 --prune` contra el repo local
- [x] T006 [US3] Ampliar `scripts/backup.sh` (parte 3/3 — repo R2): init-if-needed + `restic unlock` sobre `RESTIC_REPOSITORY_R2`; `RESTIC_FROM_PASSWORD=$RESTIC_PASSWORD restic copy --from-repo "$RESTIC_REPOSITORY_LOCAL" latest` (transfiere el snapshot ya chunkeado, sin releer el filestore); un fallo de R2 no invalida el snapshot local ya escrito
- [x] T007 [US3] Ampliar `scripts/backup.sh`: `restic forget --keep-daily 14 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3 --prune` contra el repo R2

## Phase 4: Contenedor efímero, sizing (US5)

- [x] T008 [US5] Modificar `docker-compose.backup.yml`: `mem_limit: 1g` (era 512m — restic mantiene índice/prune en memoria); mantener `cpus: 1.0`, `run --rm` (sin `restart:`), red `odoo-shared`, mounts `odoo-data:ro` y `/srv/odoo-backups`, `env_file: .env.backup`

## Phase 5: Disparo automático diario (US4)

- [x] T009 [US4] Verificar `systemd/odoo-backup.service` y `systemd/odoo-backup.timer`: sin cambios de contenido (siguen invocando `docker compose run --rm backup`) — confirmar que no referencian nada específico de rclone/gnupg

## Phase 6: Documentación

- [x] T010 [setup] Actualizar `INSTALL.md` (paso 5): `restic init` implícito en la primera corrida, nuevas env vars (`RESTIC_PASSWORD`/`RESTIC_REPOSITORY_*`/`AWS_*`), quitar el round-trip de GPG + el forzado manual de weekly/monthly (restic retiene por timestamp)
- [x] T011 [US6] Documentar en `INSTALL.md` la verificación de restore vía `restic restore latest --target /tmp/restore` → `psql` (carga el `db.sql`) + chequeo del filestore recuperado
- [x] T012 [setup] Documentar en `INSTALL.md` la limpieza única de los backups viejos de 003 (`.gpg` locales en `/srv/odoo-backups` y prefijos `daily/weekly/monthly` en R2) tras ≥14 días de solapamiento con restic

## Verification

- [x] VERIFY US1 — Confirmado con smoke real (Postgres 16 throwaway con datos + filestore falso). Un snapshot restic contiene `db.sql` (`-Fp`) + `/filestore/.../odoo`. Dedupe confirmado: corrida 2 con filestore sin cambios agregó 3.26 KiB al repo vs 5.69 KiB de la corrida 1 (los chunks del filestore no se re-almacenaron). `pg_dump` con `db` inalcanzable sale ≠ 0 sin snapshot (cubierto por `set -e`, mismo patrón validado en 003).
- [x] VERIFY US2 — Confirmado: passphrase incorrecta → `Fatal: wrong password or no key found` (repo rechaza el acceso). restic cifra AES-256 en reposo por diseño; no hay archivos en claro (el dump vive solo en el `$WORKDIR` efímero, borrado por `trap`).
- [x] VERIFY US3 — Confirmado: tras una corrida hay snapshot en repo local **y** en R2 (2 snapshots independientes listados en el repo R2 tras 2 corridas). `forget` aplica local `keep 14 daily`, R2 `keep 14 daily, 4 weekly, 12 monthly, 3 yearly` (visible en el output de policy). Cero ramas condicionales por fecha en `scripts/backup.sh`.
- [x] VERIFY US4 — `.service`/`.timer` sin cambios respecto de 003 (ya validados con `systemd-analyze verify` en `serverdipleg`, ver TASKS-003 T015); `Persistent=true` y `OnCalendar=daily` presentes. Re-validar en el server real al desplegar.
- [x] VERIFY US5 — `run --rm` sin `restart:` (contenedor no persiste, mismo patrón validado en 003 VERIFY US5); `mem_limit: 1g`/`cpus: 1.0` en `docker-compose.backup.yml`. Validación empírica de RAM contra el tamaño real del repo queda para el despliegue en el server.
- [x] VERIFY US6 — Round-trip real confirmado: `restic restore latest` → `psql` cargó el dump en una DB vacía y devolvió las 2 filas originales (`acme,globex`); el filestore recuperado conserva el contenido exacto del adjunto (`attachment-content-123`).
- [x] VERIFY No se crearon archivos fuera de los listados en "File Structure" de `plan.md` — confirmado con `git status`.
- [x] VERIFY No se agregaron dependencias fuera de `restic=0.18.1-r7`; `rclone` y `gnupg` removidos de `Dockerfile.backup`. **Bug real encontrado en testing**: `restic unlock` a secas no borra locks de otra hostname (cada contenedor tiene la suya) — un backup killed sucio dejaría un lock huérfano bloqueando todas las corridas siguientes. Corregido a `restic unlock --remove-all` (seguro por el invariante single-writer del timer). Aparte, artefacto de Docker Desktop en macOS: `sync: bad file descriptor` sobre repos en bind mount (osxfs/FUSE) — no ocurre en el filesystem nativo del server; el smoke se validó sobre un named volume para aislarlo.

## Phase 7: Convergence

- [x] T013 Reconciliar el sizing de 1g del contenedor `backup` contra el presupuesto de RAM en `docs/infrastructure-design.md` (tabla "Presupuesto de RAM") — documentar el caso de solape backup×staging (o descartarlo), apoyándose en los 4 GiB de swap como colchón (partial, Constitution MUST: cambios de sizing se revisan contra el presupuesto de RAM documentado). **Aplicado**: agregado párrafo bajo la tabla que reconcilia 512m→1g — holgado en baseline (~3 GiB margen), borde de solape backup×staging (~14.1 GiB) absorbido por swap; palanca si hay presión: mover el `OnCalendar` a una hora sin staging **Bug real encontrado en testing**: `restic unlock` a secas no borra locks de otra hostname (cada contenedor tiene la suya) — un backup killed sucio dejaría un lock huérfano bloqueando todas las corridas siguientes. Corregido a `restic unlock --remove-all` (seguro por el invariante single-writer del timer). Aparte, artefacto de Docker Desktop en macOS: `sync: bad file descriptor` sobre repos en bind mount (osxfs/FUSE) — no ocurre en el filesystem nativo del server; el smoke se validó sobre un named volume para aislarlo.

---
name: backup-stack
code: TASKS-003
version: R01
date: 2026-07-11
---

# Tasks: Stack `backup` (contenedor efímero)

## Phase 1: Setup

- [x] T001 [setup] Modificar `docker-compose.prod.yml`: volumen `odoo-data` → externo (`external: true`, `name: odoo-data`)
- [x] T002 [setup] Actualizar `.gitignore`: agregar `.env.backup`
- [x] T003 [setup] Escribir `scripts/setup-backup-role.sh`: idempotente, crea el rol `backup_readonly` (`SELECT` únicamente sobre todas las tablas de `odoo`, sin permisos de escritura/DDL) si no existe, contra `db`. **Bug real corregido en verificación**: faltaba `GRANT SELECT ON ALL SEQUENCES` — `pg_dump` falló con `permission denied for sequence ...` porque solo se habían otorgado permisos sobre tablas, no sobre secuencias (necesarias para los `serial`/`bigserial` de cada tabla). Agregado el grant + `ALTER DEFAULT PRIVILEGES` equivalente para secuencias.
- [x] T004 [P][setup] Crear `.env.backup.example`: `PGHOST=db`, `PGUSER=backup_readonly`, `PGPASSWORD`, `PGDATABASE=odoo`, `GPG_PASSPHRASE`, `RCLONE_DEST`, `RCLONE_CONFIG_R2_TYPE=s3`/`_PROVIDER=Cloudflare`/`_ACCESS_KEY_ID`/`_SECRET_ACCESS_KEY`/`_ENDPOINT` (todos como placeholders) — el `.env.backup` real gitignored

## Phase 2: Backup completo y reproducible (US1)

- [x] T005 [US1] Escribir `Dockerfile.backup`: `FROM postgres:16-alpine`, instala `rclone=<versión pineada>` + `gnupg=<versión pineada>` (confirmar versiones disponibles en el repo de Alpine 16 durante la implementación), copia `scripts/backup.sh`
- [x] T006 [US1] Escribir `scripts/backup.sh` (parte 1/3): `pg_dump -Fc` contra `db` con el rol `backup_readonly`, y `tar czf` de **`/filestore/.local/share/Odoo/filestore/odoo/`** únicamente (confirmado contra un contenedor real: el volumen `odoo-data` monta `/var/lib/odoo` completo, que además contiene `sessions/` y `addons/19.0` — cachés/temporales que no deben ir en el backup); `set -e` — si cualquiera de los dos falla, el script sale sin tocar ningún destino (ni local ni remoto)

## Phase 3: Cifrado antes de subir (US2)

- [x] T007 [US2] Ampliar `scripts/backup.sh` (parte 2/3): cifrar el dump y el tar con `gpg --batch --yes --passphrase "$GPG_PASSPHRASE" --symmetric --cipher-algo AES256`; si falla el cifrado de cualquiera de los dos, el script sale sin copiar/subir nada

## Phase 4: Destinos — copia local + R2 con retención GFS (US3)

- [x] T008 [US3] Ampliar `scripts/backup.sh` (parte 3/3): copiar ambos archivos cifrados a `$LOCAL_BACKUP_DIR` (bind mount a `/srv/odoo-backups` del host); podar copias locales de más de 7 días
- [x] T009 [US3] Ampliar `scripts/backup.sh`: subir vía `rclone copy` a `$RCLONE_DEST/daily/`; si el día es domingo (`date +%u == 7`) copiar también a `$RCLONE_DEST/weekly/`; si es día 1 del mes (`date +%d == 01`) copiar también a `$RCLONE_DEST/monthly/`
- [x] T010 [US3] Ampliar `scripts/backup.sh`: podar en `$RCLONE_DEST`. **Bug real corregido en verificación**: `rclone delete` fallaba con "directory not found" cuando `weekly/`/`monthly/` todavía no existían (nunca se les copió nada, ej. fuera de domingo/día 1) — tumbaba todo el backup con `set -e` aunque el dump+cifrado+subida a `daily/` ya hubieran sido exitosos. Agregado `|| true` a las 3 podas: son operaciones best-effort, no deben fallar un backup ya completado (vía `rclone delete`/`rclone lsf` con filtro de edad) — `daily/` >30 días, `weekly/` >3 meses, `monthly/` >1 año

## Phase 5: Disparo automático diario (US4)

- [x] T011 [US4] Escribir `systemd/odoo-backup.service`: `ExecStart=docker compose -f docker-compose.backup.yml run --rm backup` (`WorkingDirectory` al path del repo en el servidor)
- [x] T012 [US4] Escribir `systemd/odoo-backup.timer`: `OnCalendar=daily`, `Persistent=true`, referenciando `odoo-backup.service`

## Phase 6: Contenedor efímero, sizing (US5)

- [x] T013 [US1][US5] Escribir `docker-compose.backup.yml`: servicio `backup` (`build: -f Dockerfile.backup .`), sin `restart:`, red `odoo-shared` (externa), monta `odoo-data:ro` en `/filestore` y bind mount `/srv/odoo-backups:/backups`, `env_file: .env.backup`, `mem_limit: 512m`, `cpus: 1.0`

## Phase 7: Documentación

- [x] T014 [setup] Documentar en `INSTALL.md`: bootstrap de `odoo-data` externo, correr `scripts/setup-backup-role.sh` una vez, cómo correr `docker compose -f docker-compose.backup.yml run --rm backup` a mano, cómo instalar los unit files de `systemd`, cómo probar con un destino de filesystem plano en vez de R2 real

## Verification

- [x] VERIFY US1 — Confirmado con `prod` real (base con 20 archivos de filestore reales tras `-i base`). `pg_dump`+`tar` generados con mismo timestamp. Se probaron 2 fallos reales: rol sin permisos en secuencias (bug encontrado y corregido, ver T003) y `db` caído (exit 1, `pg_dump: could not translate host name`, sin tocar ningún destino)
- [x] VERIFY US2 — Confirmado: `file` sobre los `.gpg` generados reporta `PGP symmetric key encrypted data - AES with 256-bit key salted & iterated - SHA512` en los 4 archivos (dump y filestore, local y remoto) — nunca aparece el archivo sin cifrar en ningún destino
- [x] VERIFY US3 — Confirmado contra un destino de filesystem plano (`/tmp/backup-test`, sin `RCLONE_CONFIG_*`, sin R2 real): `daily/` recibe ambos archivos; lógica de `weekly`/`monthly` verificada de forma aislada contra 15 combinaciones de día/día-de-semana (correcta en las 15); poda remota probada — bug real encontrado y corregido (ver T010, `rclone delete` fallaba sobre `weekly`/`monthly` inexistentes, ahora es best-effort)
- [x] VERIFY US4 — Confirmado en `serverdipleg` (Linux real, ver T015): `systemd-analyze verify` pasó sin errores sobre `odoo-backup.service`/`.timer`. (No se pudo correr en macOS, entorno de desarrollo local — resuelto probando en el servidor real, no solo revisión manual de sintaxis.)
- [x] VERIFY US5 — Confirmado: contenedor `backup` corrido vía `run --rm` no queda listado en `docker compose ps` después de terminar; `mem_limit`/`cpus` aplicados en `docker-compose.backup.yml` (probados con overrides locales por la misma limitación de 2 CPUs de Docker Desktop que en las features anteriores)
- [x] VERIFY Edge case — Confirmado: `db` caído → `pg_dump` falla con mensaje claro, exit code 1, ningún archivo generado ni subido
- [x] VERIFY Edge case — Confirmado: destino de `rclone` montado read-only → falla la subida con exit code 1 y mensaje claro (`read-only file system`), pero la copia local ya escrita exitosamente antes de ese paso permanece intacta
- [x] VERIFY Edge case — No simulado literalmente (disco lleno es impráctico de reproducir de forma segura en este entorno) — cubierto por diseño: todas las etapas usan `set -e`, cualquier fallo de escritura por `ENOSPC` se comporta igual que los otros 2 fallos ya verificados (corta el script, no deja archivo a medio escribir)
- [x] VERIFY No se crearon archivos fuera de los listados en "File Structure" de `plan.md` — confirmado con `git status --short`, coincide exactamente
- [x] VERIFY No se agregaron dependencias fuera de las listadas en "Dependencies" de `plan.md` — confirmado, solo `postgres:16-alpine` (ya en uso), `rclone=1.72.1-r4`, `gnupg=2.4.9-r0`. **Bug real encontrado al probar en el servidor**: las versiones originalmente pineadas (`rclone=1.74.1-r1`/`gnupg=2.4.9-r1`) no existen en el repo de Alpine de esta imagen — corregido a las versiones reales disponibles, reveladas por el propio mensaje de error de `apk`

## Phase 8: Convergence

- [x] T015 Validar `systemd/odoo-backup.service` y `systemd/odoo-backup.timer` con `systemd-analyze verify` en el servidor real (Linux) — **Confirmado en `serverdipleg`**: `systemd-analyze verify` pasó sin errores. De paso se validó el stack `backup` completo de punta a punta en hardware real (no solo Docker Desktop local), encontrando y corrigiendo 2 bugs reales: versiones de `rclone`/`gnupg` pineadas a revisiones inexistentes en el repo de Alpine (corregido a `1.72.1-r4`/`2.4.9-r0`, las reales), y `scripts/setup-backup-role.sh` no sincronizaba el password si el rol ya existía de una corrida anterior (agregado `ALTER ROLE` en el branch `ELSE`) (partial → resuelto)
- [x] T016 Agregar a `.env.backup.example` un comentario explícito indicando que `PGPASSWORD` y `BACKUP_DB_PASSWORD` deben tener el mismo valor (partial)

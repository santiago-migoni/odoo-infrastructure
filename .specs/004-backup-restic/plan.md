---
name: backup-restic
code: PLAN-004
version: R00
date: 2026-07-11
---

# Plan: Migrar el stack de backup a restic

## Approach

Se reescribe el stack de backup existente (003) sobre `restic` en vez de `rclone` + `gnupg` + `tar/gzip` + GFS-en-bash. La misma imagen base (`postgres:16-alpine`, para el `pg_dump` compatible con la versión real de la DB) instala `restic` en lugar de `rclone`+`gnupg`. El script queda a "dump plano → `restic backup` (dump + filestore en un snapshot) → `restic forget --prune`", una vez por repo. Dos repos restic independientes: uno **local** (`/backups/restic`, bind mount a `/srv/odoo-backups`) y uno en **R2** (backend S3 nativo de restic). El cifrado (AES-256), la deduplicación y la retención GFS los provee restic — desaparecen `gnupg`, el `tar` manual y toda la lógica condicional de día-de-semana/día-de-mes. Contenedor efímero, red, rol RO y timer se mantienen igual que en 003.

## Constitution Check

- **Tech stack — CONFLICTO A RESOLVER**: la constitución (línea "Backups") fija `postgres:16-alpine` + `rclone` + `gnupg`. Este plan reemplaza `rclone`+`gnupg` por `restic`. **Requiere enmienda de la constitución (R03)** actualizando la descripción de Backups a `postgres:16-alpine` + `restic` antes de aprobar/implementar. La imagen base (`postgres:16-alpine`) no cambia, así que el resto de la línea se mantiene.
- **Code principles aplicables**: "todo backup completo = DB + filestore juntos" (US1 — ahora en un mismo snapshot restic, más fuerte que antes); "RAM es el recurso más restrictivo" (US5, sizing — restic mantiene índice en memoria, ver Risks); "nunca usar tag latest" (imagen base y `restic` pineados).
- **Constraints**: sin credenciales reales de R2 en el repo (mismo patrón `.env.backup` gitignored); servidor único de 14 GiB — el contenedor sigue siendo efímero, no compite por RAM fuera de su ventana.

## Architecture

```text
systemd timer (diario) ──▶ docker compose run --rm backup
                                      │
                         pg_dump -Fp (rol RO) ──▶ $WORKDIR/db.sql
                                      │           (nombre estable, no timestamped:
                                      │            maximiza el dedupe de restic)
                                      │
                    ▼
          REPO LOCAL (/backups/restic)
          restic backup db.sql + filestore   ◀── única lectura/chunkeo del filestore
          restic forget --keep-daily 14 --prune
                    │
                    │  restic copy --from-repo LOCAL latest  (transfiere packs ya chunkeados)
                    ▼
          REPO R2 (s3:...r2.cloudflarestorage.com)
          restic forget --keep-daily 14 --keep-weekly 4
                        --keep-monthly 12 --keep-yearly 3 --prune
```

- **Un snapshot = DB + filestore juntos**: `restic backup "$DUMP_FILE" /filestore/.local/share/Odoo/filestore/odoo` en una sola invocación → el snapshot es un punto de restauración atómico. El dump se escribe con **nombre estable** (`db.sql`, no `db-<timestamp>.sql`): restic ya fecha cada snapshot, y un path estable maximiza el dedupe (tablas sin cambios = mismos bloques) y deja el listado de snapshots limpio.
- **`pg_dump -Fp` (plano)** en vez de `-Fc`: el formato comprimido rompía el dedupe de restic; plano deja que restic comprima y deduplique. Restore vía `psql` (no `pg_restore -j`) — trade-off aceptado en clarificación.
- **Local primero, luego `restic copy` local→R2**: el `restic backup` corre una sola vez, contra el repo local (disco, rápido). El repo R2 se puebla con `restic copy --from-repo "$RESTIC_REPOSITORY_LOCAL" latest` — transfiere los packs ya cifrados/chunkeados del repo local, **sin releer ni re-chunkear el filestore** (resuelve el riesgo de doble lectura). Ambos repos comparten `RESTIC_PASSWORD` (vía `RESTIC_FROM_PASSWORD=$RESTIC_PASSWORD` para el origen del copy). Si R2 falla, el snapshot local ya está completo (US3 edge case).
- **Init idempotente**: antes del primer `backup` en cada repo, `restic cat config >/dev/null 2>&1 || restic init` — crea el repo solo si no existe, seguro de re-correr.
- **Locks stale**: `restic unlock` antes de cada backup — una corrida previa matada puede dejar un lock; como el timer garantiza una sola corrida por vez, quitar el lock stale es seguro (no hay concurrencia real).
- **Config de restic por env vars** (mismo patrón que rclone/PgBouncer, sin archivo): `RESTIC_PASSWORD`, `RESTIC_REPOSITORY_LOCAL`, `RESTIC_REPOSITORY_R2`, y para el backend S3 de R2 `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` (nombres que restic espera para S3, reemplazan a los `RCLONE_CONFIG_R2_*`). Para testing sin R2 real, el repo R2 puede apuntarse a una segunda ruta de filesystem local — restic trata cualquier path como repo local, sin necesidad de S3 (mismo espíritu que el "remote local" de rclone en 003).
- **Rol de Postgres RO, red, volumen, contenedor efímero**: sin cambios respecto de 003 (`odoo-data:ro`, red `odoo-shared`, `backup_readonly`, `run --rm`).

## File Structure

```text
odoo-infrastructure/
├── Dockerfile.backup            ← modificado. FROM postgres:16-alpine; apk add restic=0.18.1-r7 (confirmado disponible en Alpine v3.24 community de esta imagen); quita rclone + gnupg; copia scripts/backup.sh
├── scripts/backup.sh            ← reescrito. pg_dump -Fp + local (init-if-needed → unlock → restic backup dump+filestore → forget --prune) + R2 (init-if-needed → unlock → restic copy --from-repo LOCAL latest → forget --prune). Quita tar, gpg, rclone y toda la lógica de calendario
├── scripts/setup-backup-role.sh ← sin cambios (el rol RO y pg_dump siguen igual)
├── docker-compose.backup.yml    ← modificado. Mismos mounts (odoo-data:ro, /srv/odoo-backups); sizing revisado (ver Risks); env_file .env.backup
├── .env.backup.example          ← reescrito. RESTIC_PASSWORD, RESTIC_REPOSITORY_LOCAL, RESTIC_REPOSITORY_R2, AWS_ACCESS_KEY_ID/SECRET (reemplazan GPG_PASSPHRASE y RCLONE_CONFIG_R2_*); PG* y BACKUP_DB_PASSWORD se mantienen
├── systemd/odoo-backup.service  ← sin cambios
├── systemd/odoo-backup.timer    ← sin cambios
├── INSTALL.md                   ← modificado. Paso 5: restic init de ambos repos, nuevas env vars, verificación de restore vía `restic restore` → `psql` (reemplaza el round-trip de gpg + pg_restore --list); forzado manual de weekly/monthly ya no aplica (restic retiene por timestamp); nota de limpieza única de los .gpg viejos de 003 tras validar restic (ver Risks)
└── .specs/constitution.md       ← modificado (R03). Backups: rclone + gnupg → restic
```

## Data Model

N/A — opera sobre datos existentes de Odoo/Postgres, sin modelo propio.

## API / Interface Contracts

- **`backup`** (imagen `Dockerfile.backup`): env vía `.env.backup` — `PGHOST=db`, `PGUSER=backup_readonly`, `PGPASSWORD`, `PGDATABASE=odoo` (sin cambios); `RESTIC_PASSWORD` (passphrase de cifrado, compartida por ambos repos); `RESTIC_REPOSITORY_LOCAL=/backups/restic`; `RESTIC_REPOSITORY_R2=s3:https://<accountid>.r2.cloudflarestorage.com/<bucket>` con `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`. En test, `RESTIC_REPOSITORY_R2` puede ser una ruta de filesystem plana sin credenciales S3.
- **`scripts/backup.sh`** — contrato de comportamiento: sale con exit ≠ 0 sin crear ningún snapshot si falla `pg_dump`; el `restic backup` corre solo contra el repo local, y R2 se puebla por `restic copy` — un fallo de R2 no invalida el snapshot local ya escrito; retención aplicada por repo (local `--keep-daily 14`; R2 `--keep-daily 14 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3`).
- **Rol de Postgres `backup_readonly`**: sin cambios respecto de 003 — `SELECT` únicamente sobre tablas y secuencias de `odoo`.

## Dependencies

- `postgres:16-alpine` — sin cambios (misma versión que `db`, garantiza compatibilidad de `pg_dump`).
- `restic=0.18.1-r7` (Alpine v3.24 community, **confirmado disponible** en `postgres:16-alpine` vía `apk add`). **Reemplaza** a `rclone` y `gnupg`, que se quitan.
- Sin dependencias nuevas fuera de restic.

## Risks & Unknowns

Todos los riesgos identificados quedan resueltos abajo; ninguno bloquea `spec-flow:tasks`.

- **Versión de `restic` — RESUELTO.** Confirmado empíricamente contra la imagen real (`docker run postgres:16-alpine` + `apk add`): `restic 0.18.1-r7` disponible en Alpine v3.24 community. Se pinea a esa versión. (La 0.18 además trae el `prune` de bajo consumo de memoria, relevante para el riesgo siguiente.)
- **Sizing / memoria de restic — RESUELTO (validación empírica en implement).** Se fija `mem_limit: 1g` / `cpus: 1.0`. Fundamento: restic 0.18 hace `prune` sin cargar todo el índice en memoria (mejora de las versiones 0.14+), y el pico de RAM lo marca `prune`, no `backup`. Para un repo de pocos GB el índice es de decenas de MB; 1g deja margen amplio. El contenedor es efímero y corre de noche (staging abajo), así que 1g en su ventana entra cómodo en el presupuesto de RAM. Igual se valida con `docker inspect` + tamaño real del repo en implement, como en features anteriores.
- **Doble lectura del filestore — RESUELTO por diseño.** Se elimina el segundo `restic backup`: el filestore se lee/chunkea **una sola vez** contra el repo local, y R2 se puebla con `restic copy --from-repo LOCAL latest`, que transfiere packs ya cifrados sin releer el origen. Menos I/O y menos CPU que la propuesta inicial de dos backups.
- **Backups viejos de 003 sin podar tras la migración — RESUELTO (paso manual documentado).** Al reemplazar el script, la poda GFS-en-bash desaparece, así que los `.gpg` de 003 (local en `/srv/odoo-backups` y en los prefijos `daily/weekly/monthly` de R2) ya no se podan solos. Se documenta en INSTALL.md una **limpieza única**: tras validar que restic viene corriendo bien (≥14 días de solapamiento, cubriendo la retención diaria), borrar a mano los `.gpg` viejos y sus prefijos en R2. El repo restic arranca vacío; no hay conversión de formato.
- **Enmienda de constitución (R03) — RESUELTO (acción previa a implement).** El conflicto rclone+gnupg → restic se corrige con `spec-flow:constitution` antes de `spec-flow:implement`. No lo hace este plan, pero queda como gate explícito: no se implementa sin la enmienda.

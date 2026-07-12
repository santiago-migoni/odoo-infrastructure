---
name: backup-restic
code: SPEC-004
version: R00
date: 2026-07-12
status: Converged
---

# Spec: Migrar el stack de backup a restic

## Summary

Reemplaza el stack de backup actual (`rclone` + `gnupg` + `tar/gzip` + lógica GFS escrita a mano en bash) por `restic`, que trae cifrado en reposo, deduplicación, retención GFS declarativa y soporte S3/R2 nativo en una sola herramienta — reduciendo el script a "dump + snapshot + forget" y bajando drásticamente lo que se sube cada día.

## User Stories

### US1 — Backup completo y reproducible en un solo snapshot (P1)

Como operador, quiero que cada corrida capture la DB y el filestore juntos en un mismo punto de restauración, para que nunca queden desincronizados.

**Acceptance Scenarios**:
- **Given** `prod` corriendo con datos reales, **When** se ejecuta el backup, **Then** se genera un snapshot de restic que contiene el dump de la DB (`pg_dump -Fp`, plano) y el filestore de Odoo (`/filestore/.local/share/Odoo/filestore/odoo/`) como un único punto de restauración.
- **Given** `db` caído o inaccesible, **When** se ejecuta el backup, **Then** el script falla con exit code ≠ 0 sin crear ningún snapshot (ni local ni R2).
- **Given** un segundo backup el mismo día con el filestore sin cambios, **When** corre, **Then** restic deduplica y el snapshot nuevo sube solo los bloques cambiados (no el filestore completo de nuevo).

### US2 — Cifrado en reposo, siempre (P1)

Como operador, quiero que todo backup esté cifrado en el destino sin un paso manual de GPG, para que un acceso al bucket o al disco local no exponga datos de clientes.

**Acceptance Scenarios**:
- **Given** un repo restic inicializado, **When** se inspecciona cualquier destino (local o R2), **Then** los datos están cifrados en reposo por restic (AES-256) y no hay ningún archivo de dump/filestore en claro en ningún destino.
- **Given** una passphrase incorrecta, **When** se intenta listar o restaurar, **Then** restic rechaza el acceso.

### US3 — Dos destinos con retención GFS declarativa (P1)

Como operador, quiero un repo local (restore rápido) y uno en R2 (off-site), cada uno con su política de retención aplicada por restic — sin lógica de calendario en bash.

**Acceptance Scenarios**:
- **Given** un backup exitoso, **When** termina, **Then** existe un snapshot nuevo tanto en el repo local (`/srv/odoo-backups`) como en el repo R2.
- **Given** el repo local, **When** corre `restic forget --prune`, **Then** se retienen las 14 diarias más recientes (`--keep-daily 14`).
- **Given** el repo R2, **When** corre `restic forget --prune`, **Then** se retienen 14 diarias + 4 semanales + 12 mensuales + 3 anuales (`--keep-daily 14 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3`).
- **Given** que hoy no es domingo ni día 1, **When** corre el backup, **Then** no hay ninguna rama condicional por fecha — restic decide qué retener por los timestamps de los snapshots.

### US4 — Disparo automático diario (P2)

Como operador, quiero que el backup corra solo, una vez al día, disparado por el mismo mecanismo actual.

**Acceptance Scenarios**:
- **Given** el timer de systemd instalado, **When** llega la hora programada, **Then** se ejecuta `docker compose -f docker-compose.backup.yml run --rm backup` una vez.
- **Given** el servidor apagado a la hora programada, **When** vuelve a encender, **Then** el backup saltado corre en el próximo boot (`Persistent=true`).

### US5 — Contenedor efímero con sizing acotado (P2)

Como operador, quiero que el contenedor de backup exista solo mientras corre y con límites de recursos, para no gastar RAM (el recurso más ajustado) ni mantener credenciales vivas de más.

**Acceptance Scenarios**:
- **Given** el backup terminado, **When** se lista `docker compose ps`, **Then** el contenedor no aparece (se corrió con `run --rm`, sin `restart:`).
- **Given** el contenedor corriendo, **When** se inspecciona, **Then** tiene `mem_limit` y `cpus` aplicados y revisados contra el presupuesto de RAM.

### US6 — Restore genuinamente verificable (P1)

Como operador, quiero poder confirmar que un backup es recuperable de verdad, no solo que el snapshot existe.

**Acceptance Scenarios**:
- **Given** un snapshot en el repo local, **When** se restaura a un directorio temporal, **Then** el dump plano se puede cargar con `psql` en una DB vacía y el filestore se recupera íntegro.
- **Given** el repo R2, **When** se lista con `restic snapshots`, **Then** el snapshot del día aparece con su timestamp y paths.

## Edge Cases

- **Repo no inicializado (primera corrida)**: el script hace `restic init` idempotente (o detecta que ya existe) antes del primer `backup`, en ambos repos.
- **R2 caído pero local OK**: el snapshot local se completa; el fallo de R2 corta el script con exit ≠ 0 y queda registrado, pero el punto de restauración local ya existe.
- **Lock de restic tras una corrida abortada**: una corrida previa matada puede dejar un lock stale; el script debe poder recuperarse (`restic unlock` acotado) sin borrar datos.
- **Disco local lleno durante el snapshot local**: falla con exit ≠ 0, sin dejar el repo local corrupto (restic es transaccional por diseño).

## Explicit Non-Goals

- **No cambia el rol de Postgres de solo lectura** (`backup_readonly`) ni `scripts/setup-backup-role.sh` — se sigue usando tal cual para el `pg_dump`.
- **No cambia el flujo de restore de staging** (`004`→`005` staging) ni asume nada sobre él; esta feature solo produce backups, no los consume.
- **No usa reglas de lifecycle de R2** — la retención la maneja restic (`forget --prune`), igual que hoy la manejaba el script.
- **No migra ni convierte los backups viejos** (formato `rclone` + `.gpg`) al repo restic — arranca un repo nuevo; los backups previos se retienen aparte hasta que venzan por su cuenta.
- **No cambia el disparo** (systemd timer diario) más allá de lo necesario para invocar el nuevo script.

## Open Questions

- Ninguna pendiente — decisiones de formato (`pg_dump -Fp`), destinos (repo local + R2) y retención (local 14d; R2 14d/4w/12m/3y) resueltas en clarificación.

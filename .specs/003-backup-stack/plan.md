---
name: backup-stack
code: PLAN-003
version: R01
date: 2026-07-11
---

# Plan: Stack `backup` (contenedor efímero)

## Approach

Un `Dockerfile.backup` propio (`FROM postgres:16-alpine` + `rclone` + `gnupg`) y un `docker-compose.backup.yml` con un único servicio `backup`, sin `restart:` (se invoca vía `docker compose run --rm`, nunca queda corriendo). Se conecta a la red externa `odoo-shared` (feature `edge`) para alcanzar `db`, con un usuario de Postgres dedicado de solo lectura, y monta el volumen `odoo-data` (ahora externo) `:ro` para el filestore. Toda la lógica de dump+tar+cifrado+subida+retención GFS vive en un script propio (`scripts/backup.sh`), no en configuración de Postgres/rclone declarativa — así queda testeable localmente sin R2 real.

## Constitution Check

- **Tech stack**: contenedor efímero `postgres:16-alpine` + `rclone` + `gnupg` — coincide exactamente con lo definido en la constitución (Backups).
- **Code principles aplicables**: "todo backup completo = DB + filestore juntos" (US1); "RAM es el recurso más restrictivo" (US5, sizing); "nunca usar tag latest" (imagen base pineada).
- **Constraints**: sin credenciales reales de R2 en el repo (mismo patrón que `TUNNEL_TOKEN`); servidor único de 14 GiB compartido — el contenedor es efímero, no compite por RAM fuera de su ventana de ejecución.
- Sin conflictos detectados.

## Architecture

```text
systemd timer (diario) ──▶ docker compose run --rm backup
                                      │
                    ┌─────────────────┼─────────────────┐
                    │                 │                 │
              pg_dump (rol RO)   tar filestore      (red odoo-shared)
              contra db:5432     (odoo-data :ro)
                    │                 │
                    └────────┬────────┘
                             ▼
                    gpg --symmetric (AES256)
                             │
                ┌────────────┴────────────┐
                ▼                         ▼
      bind mount local              rclone (env-var config)
      /srv/odoo-backups             daily/ + weekly/ + monthly/
      (rolling 7 días)              (poda GFS: 30d/3m/1a, propia del script)
```

- **Red**: `backup` se une a `odoo-shared` (externa, ya creada por la feature `edge`) para resolver `db` por nombre — mismo patrón que `traefik`/`cloudflared`.
- **Volumen filestore**: `odoo-data` pasa de project-scoped (feature 1) a externo (`docker volume create odoo-data`), igual que se hizo con la red en `edge`. `docker-compose.prod.yml` se ajusta para referenciarlo como externo — sin tocar el volumen `db-data` (backup no lo necesita, hace `pg_dump` por red, no accede al datadir). **Confirmado contra un contenedor real**: el volumen monta `/var/lib/odoo` completo, y el filestore real vive anidado en `/var/lib/odoo/.local/share/Odoo/filestore/odoo/` — el `tar` debe apuntar específicamente ahí, no a la raíz del volumen (que también contiene `sessions/` y `addons/19.0`, cachés/temporales que no son parte del backup).
- **Rol de Postgres de solo lectura**: se crea una única vez, disparado a mano por el operador (no vía `docker-entrypoint-initdb.d`, que solo corre en un datadir nuevo/vacío — la base de prod ya va a tener datos para cuando se agregue este rol), pero mediante un script idempotente versionado (`scripts/setup-backup-role.sh`, ver File Structure) en vez de instrucciones en prosa para copiar a mano — reduce el riesgo de un SQL mal tipeado, y es seguro re-correrlo si el rol ya existe.
- **Config de `rclone` sin archivo**: se configura 100% por variables de entorno (`RCLONE_CONFIG_R2_TYPE=s3`, `RCLONE_CONFIG_R2_PROVIDER=Cloudflare`, `_ACCESS_KEY_ID`, `_SECRET_ACCESS_KEY`, `_ENDPOINT=https://<accountid>.r2.cloudflarestorage.com`), vía `.env.backup` — mismo patrón que PgBouncer en la feature 1 (config por env vars, sin archivo `.ini`/`.conf` propio). Valores confirmados contra la documentación oficial de Cloudflare R2 + `rclone` (no un ejemplo genérico). Para probar sin R2 real, el script recibe directamente una **ruta de filesystem plana** como destino (`rclone` la trata como backend local automáticamente, sin necesidad de `RCLONE_CONFIG_*` ni de levantar MinIO/ningún servidor S3 de prueba) — mismo script, solo cambia el valor de destino entre test y prod.

## File Structure

```text
odoo-infrastructure/
├── Dockerfile.backup            ← nuevo. FROM postgres:16-alpine, instala rclone + gnupg con versión pineada (a confirmar contra el repo de paquetes de Alpine en implementación), copia scripts/backup.sh
├── docker-compose.backup.yml    ← nuevo. Servicio `backup` (sin restart:, red odoo-shared, monta odoo-data :ro y /srv/odoo-backups), mem_limit/cpus
├── scripts/
│   ├── backup.sh                 ← nuevo. pg_dump (rol RO) + tar filestore + gpg simétrico + copia local (7d) + rclone a daily/weekly/monthly + poda remota GFS
│   └── setup-backup-role.sh      ← nuevo. Idempotente — crea el rol `backup_readonly` (SELECT únicamente) si no existe. Se corre a mano, una vez, contra `db`
├── systemd/
│   ├── odoo-backup.service      ← nuevo. Unit que corre `docker compose -f docker-compose.backup.yml run --rm backup`
│   └── odoo-backup.timer        ← nuevo. Timer diario, referencia al .service
├── docker-compose.prod.yml      ← modificado. Volumen `odoo-data` → externo (`external: true`, `name: odoo-data`)
├── .env.backup.example           ← nuevo. Plantilla: credenciales del rol RO de Postgres, GPG_PASSPHRASE, RCLONE_CONFIG_* — el .env.backup real gitignored
├── .gitignore                    ← modificado. Agrega `.env.backup`
└── INSTALL.md                    ← modificado. Agrega: bootstrap de `odoo-data` externo, creación manual del rol `backup_readonly`, cómo correr/instalar el timer, cómo probar con remote `local` de rclone
```

## Data Model

N/A — sin modelo de datos propio (el backup opera sobre datos ya existentes de Odoo/Postgres).

## API / Interface Contracts

- **`backup`** (imagen propia `Dockerfile.backup`): env vía `.env.backup` — `PGHOST=db`, `PGUSER=backup_readonly`, `PGPASSWORD`, `PGDATABASE=odoo`, `GPG_PASSPHRASE`, `RCLONE_DEST` (en prod: `r2:bucket-name`, con `RCLONE_CONFIG_R2_TYPE=s3`/`_PROVIDER=Cloudflare`/`_ACCESS_KEY_ID`/`_SECRET_ACCESS_KEY`/`_ENDPOINT` seteados; en test: una ruta de filesystem plana, sin ningún `RCLONE_CONFIG_*`), `LOCAL_BACKUP_DIR=/backups` (bind-mounted a `/srv/odoo-backups` del host).
- **`scripts/backup.sh`** — contrato de comportamiento (no una API formal): sale con exit code ≠ 0 y sin tocar ningún destino si falla el `pg_dump`, el `tar`, o el cifrado; solo sube/copia si las 3 etapas previas fueron exitosas.
- **Rol de Postgres `backup_readonly`**: `SELECT` únicamente sobre todas las tablas de la base `odoo`, sin permisos de escritura/DDL.

## Dependencies

- `postgres:16-alpine` (misma versión que `db` en producción — garantiza compatibilidad de `pg_dump` con el formato del servidor real).
- `rclone` (paquete, instalado en la imagen — sin servidor/daemon adicional).
- `gnupg` (paquete, instalado en la imagen).
- Sin dependencias nuevas fuera de estas tres.

## Risks & Unknowns

- **Variables de entorno de `rclone` para S3/R2 — resuelto.** Confirmado contra la documentación oficial de Cloudflare R2 y `rclone`: `RCLONE_CONFIG_R2_TYPE=s3`, `RCLONE_CONFIG_R2_PROVIDER=Cloudflare` (no `other`), más `_ACCESS_KEY_ID`/`_SECRET_ACCESS_KEY`/`_ENDPOINT`. Para testing, ni siquiera hace falta un remote configurado — una ruta de filesystem plana alcanza.
- **Timing de creación del rol `backup_readonly` — mitigado.** Sigue siendo un paso manual (no se automatiza vía `docker-entrypoint-initdb.d`, que no aplica sobre una base con datos existentes), pero pasa de instrucciones en prosa a un script idempotente versionado (`scripts/setup-backup-role.sh`) — reduce el riesgo de error humano al tipear el SQL, y es seguro re-correrlo si el rol se pierde (ej. tras recrear `db` desde cero).
- **Sizing de `backup` — mitigado con argumento técnico, validación empírica pendiente.** No hay dato de referencia previo (nunca se dimensionó este contenedor), pero `pg_dump`, `tar` y `gpg --symmetric` son herramientas que **streamean** datos — ninguna carga el dataset completo en memoria, el overhead es de buffers (decenas de MB), no proporcional al tamaño de la DB/filestore. `mem_limit: 512m`/`cpus: 1.0` da margen cómodo bajo ese razonamiento; queda validar con `docker inspect` y el tamaño real del filestore una vez implementado, igual que en las features anteriores.

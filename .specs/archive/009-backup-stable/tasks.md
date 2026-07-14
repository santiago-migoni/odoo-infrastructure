---
name: backup-stable
code: TASKS-009
version: R00
date: 2026-07-13
---

# Tasks: Stack `backup` siempre-arriba

## Phase 1: Contenedor siempre-arriba (US1)

- [x] T001 [US1] Modificar `docker/docker-compose.backup.yml`: agregar `entrypoint: ["sleep", "infinity"]` (override explícito — el `ENTRYPOINT` del `Dockerfile.backup` sigue siendo `backup.sh`, esto solo cambia el proceso principal del servicio de compose) y `restart: unless-stopped`
- [x] T002 [P][US1] Modificar `Makefile`: targets `backup`/`backup-backup-run` de `$(COMPOSE_BACKUP) run --rm backup` a `$(COMPOSE_BACKUP) exec -T backup /usr/local/bin/backup.sh`

## Phase 2: Disparo diario vía systemd exec (US2)

- [x] T003 [US2] Modificar `systemd/odoo-backup.service`: `ExecStart` de `docker compose -f docker/docker-compose.backup.yml run --rm backup` a `docker compose -f docker/docker-compose.backup.yml exec -T backup /usr/local/bin/backup.sh`

## Phase 3: Healthcheck por freshness (US3)

- [x] T004 [US3] Modificar `scripts/backup.sh`: agregar `touch /backups/.last-success` como última línea, después del `restic forget --prune` del repo R2 — solo se toca si todo lo anterior salió bien (bajo `set -e`)
- [x] T005 [US3] Depende de T004 — Modificar `docker/docker-compose.backup.yml`: agregar `healthcheck` (`test: ["CMD-SHELL", "test -f /backups/.last-success && [ $(($(date +%s) - $(stat -c %Y /backups/.last-success))) -lt 93600 ]"]`, `interval: 1h`, `timeout: 10s`, `retries: 1`, `start_period: 5m`) — 93600s = 26h

## Phase 4: Documentación

- [x] T006 [P] Actualizar `INSTALL.md` (paso 5, Stack `backup`): el primer arranque pasa de un `run --rm` único a dos comandos — `docker compose -f docker/docker-compose.backup.yml up -d backup` (levanta el contenedor idle) + `docker compose -f docker/docker-compose.backup.yml exec -T backup /usr/local/bin/backup.sh` (dispara la primera corrida real); nota breve sobre el healthcheck de freshness
- [x] T007 [P] Actualizar `docs/infrastructure-design.md`: fila de Backup en la tabla de RAM — nota de que ahora paga su footprint "Bajo" (~100MB) 24/7 en vez de ~0 fuera de la ventana de ejecución (sin cambiar `mem_limit`, sigue en `1g`)

## Verification

- [x] VERIFY US1 — **Confirmado con contenedor real, mitigación del riesgo de loop de reinicio (plan.md Risks)**: `docker exec backup-test ps` mostró `PID 1 = sleep infinity` (no `backup.sh`); tras correr un `backup.sh` real completo dentro del contenedor, el proceso principal siguió siendo `sleep infinity` (no se relanzó ni se recreó); un `docker restart` manual confirmó `RestartCount=0` y el mismo `sleep infinity` como PID 1 tras el restart — cero evidencia de loop.
- [x] VERIFY US2 — **Confirmado con smoke real**: `docker exec ... backup-test /usr/local/bin/backup.sh` (equivalente exacto al `ExecStart` de systemd) corrió a completitud contra un `db` real + repos restic reales (local + "R2" de filesystem), produciendo snapshots reales en ambos repos — mismo `CONTAINER ID` antes y después, el contenedor nunca se recreó. `systemd-analyze` no está disponible en este sandbox macOS (esperado); revisión manual de sintaxis INI de `odoo-backup.service`/`.timer` sin hallazgos — ejecución real del timer queda reservada a deploy en Linux real, mismo criterio que 003/005/007.
- [x] VERIFY US3 — **Confirmado con smoke real, riesgo de `stat -c %Y` en Alpine descartado (plan.md Risks)**: `docker inspect .Config.Healthcheck.Test` mostró el comando real ejecutado por el daemon con `$` simple (correcto — el `$$` visto en `docker compose config` era solo un artefacto de display round-trip-safe, no lo que corre); `stat -c %Y` funcionó sin problema en `postgres:16-alpine` durante docenas de evaluaciones reales del healthcheck — no hizo falta el fallback de `find -mmin`. Ciclo completo confirmado real: sin marcador → `unhealthy`; `backup.sh` exitoso → marcador creado → `healthy`; marcador adelantado a 27h (`touch -t`, sintaxis BSD) → `unhealthy`; corrida fallida (credenciales de DB incorrectas, corta en `pg_dump` bajo `set -e`) → mtime del marcador sin cambios (confirmado byte a byte); `docker restart` → marcador y PID 1 (`sleep infinity`) sobreviven intactos, vive en el bind mount, no en el filesystem efímero del contenedor.
- [x] VERIFY No se crearon archivos fuera de los listados en "File Structure" de `plan.md` — confirmado con `git status`: coincide exactamente (los 6 archivos del plan + `.specs/009-backup-stable/`; `.specs/backlog.md`/`.specs/constitution.md` son de la sesión previa de `/grilling`+`/constitution`, `CLAUDE.md` es el diff de formato preexistente ajeno a esta feature).
- [x] VERIFY Sin dependencias nuevas — confirmado: `docker/Dockerfile.backup` sin cambios (`git diff --stat` vacío), `stat`/`date`/`test`/`sleep` ya presentes en `postgres:16-alpine` y usados/confirmados reales en las VERIFY anteriores.

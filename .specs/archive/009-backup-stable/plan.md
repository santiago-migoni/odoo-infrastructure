---
name: backup-stable
code: PLAN-009
version: R00
date: 2026-07-13
---

# Plan: Stack `backup` siempre-arriba

## Approach

El contenedor pasa de `run --rm` (crea, corre `backup.sh`, muere) a `restart: unless-stopped` con un `entrypoint:` idle (`sleep infinity`) a nivel compose — el `Dockerfile.backup` no se toca, su `ENTRYPOINT` sigue siendo `backup.sh` para cualquier uso standalone, pero el servicio de compose lo overridea. El systemd timer diario pasa de `docker compose run --rm backup` a `docker compose exec backup /usr/local/bin/backup.sh` contra el contenedor ya vivo. `backup.sh` gana una línea al final (tras el éxito de ambos repos) que toca un marcador con timestamp en `/backups/.last-success`; un `HEALTHCHECK` a nivel compose lee ese marcador y falla si tiene más de ~26h. Cero dependencias nuevas, cero cambios al mecanismo de backup en sí.

## Constitution Check

- **Tech stack (R04)**: "contenedor siempre-arriba... disparo vía systemd timer diario (`docker compose exec`, nunca `run --rm`)" → exactamente lo que entrega este plan. ✓
- **Code principles aplicables**:
  - "Todo scheduling recurrente usa systemd timers, nunca cron embebido" (R04) → el timer existente se mantiene, solo cambia su `ExecStart`. ✓
  - "Todo backup completo = DB + filestore juntos" → sin cambios, `backup.sh` sigue respaldando ambos en la misma corrida. ✓
  - "RAM es el recurso más restrictivo" → `mem_limit: 1g` ya cubre tanto el reposo (Bajo, ~100MB) como el pico de una corrida activa (ya sizeado para eso); lo que cambia es que ahora paga *algo* de RAM 24/7 en vez de ~0 fuera de la ventana — impacto en el presupuesto documentado en Risks. ✓ (revisado, no bloqueante)
- Sin conflictos detectados.

## Architecture

```text
Antes:                                          Después:
systemd timer (diario)                          systemd timer (diario) — sin cambios
  └─ docker compose run --rm backup                └─ docker compose exec -T backup backup.sh
       (crea contenedor, corre backup.sh,                (contenedor YA está corriendo,
        contenedor muere al terminar)                     entrypoint real = sleep infinity)

                                                 docker-compose.backup.yml:
                                                   entrypoint: ["sleep", "infinity"]  ◀── override, Dockerfile intacto
                                                   restart: unless-stopped
                                                   healthcheck: lee /backups/.last-success

                                                 backup.sh: + 1 línea al final
                                                   touch /backups/.last-success   (solo si ambos repos ok)
```

- **Por qué `entrypoint:` y no `command:`**: `Dockerfile.backup` define `ENTRYPOINT ["/usr/local/bin/backup.sh"]` (forma exec). Si el compose solo overrideara `command:`, Docker concatenaría `backup.sh sleep infinity` — pasaría `sleep`/`infinity` como *argumentos* de `backup.sh`, no reemplazaría el proceso. Hace falta `entrypoint:` explícito para que el proceso principal del contenedor sea realmente idle.
- **Marcador de salud**: `/backups/.last-success` vive en el mismo bind mount que ya existe (`/srv/odoo-backups:/backups`, host↔contenedor) — sobrevive un `docker compose restart`/recreación del contenedor porque no es parte del filesystem efímero del contenedor. Se toca al final de `backup.sh`, después del `restic forget --prune` del repo R2 (el último paso que puede fallar) — si cualquier paso anterior falla, `set -e` corta antes de llegar a esa línea y el marcador queda con el timestamp de la última corrida *realmente* exitosa.
- **`HEALTHCHECK`**: a nivel `docker-compose.backup.yml` (mismo patrón que `db`/`pgbouncer`/`traefik` ya usan en sus propios compose), no horneado en el Dockerfile — permite tunear el umbral de 26h sin rebuild de imagen. Usa solo `test`/`stat`/`date` (busybox de Alpine, ya presentes, sin paquetes nuevos).
- **Primer arranque (INSTALL.md)**: cambia de "un solo `run --rm` que hace todo" a dos pasos — `up -d backup` (levanta el contenedor idle) + `exec -T backup /usr/local/bin/backup.sh` (dispara la primera corrida real) — mismo patrón que usará el timer de ahí en adelante.
- **Comandos diagnósticos existentes** (`run --rm --entrypoint restic backup -r ... snapshots/restore`, en INSTALL.md) no cambian — `run` crea una instancia temporal separada del servicio persistente, y ya pasan `--entrypoint restic` explícito, así que el override de compose no los afecta.
- **Makefile**: `backup`/`backup-backup-run` (targets especiales de 008) pasan de `run --rm backup` a `exec -T backup /usr/local/bin/backup.sh`, coherentes con el nuevo patrón — evita levantar una segunda instancia del contenedor por accidente cuando la estable ya está arriba. Los compuestos genéricos `backup-up`/`backup-down`/`backup-status`/`backup-logs` (ya generados por el template de 008) no cambian — `backup-up` ahora sí tiene sentido real (antes no había nada persistente que "subir").

## File Structure

```text
odoo-infrastructure/
├── docker/docker-compose.backup.yml   ← modificado: + entrypoint: ["sleep", "infinity"], + restart: unless-stopped, + healthcheck (test/interval/timeout/retries/start_period)
├── scripts/backup.sh                  ← modificado: + `touch /backups/.last-success` al final, tras el `restic forget --prune` del repo R2
├── systemd/odoo-backup.service        ← modificado: ExecStart de `run --rm backup` a `exec -T backup /usr/local/bin/backup.sh`
├── systemd/odoo-backup.timer          ← sin cambios (OnCalendar=daily ya es lo correcto)
├── Makefile                           ← modificado: targets `backup`/`backup-backup-run` de `run --rm` a `exec -T`
├── INSTALL.md                         ← modificado: paso 5 — primer arranque pasa a `up -d` + `exec` (dos comandos en vez de uno); nota sobre el healthcheck
└── docs/infrastructure-design.md      ← modificado: fila de Backup en la tabla de RAM, nota de que ahora paga su costo "Bajo" 24/7 en vez de ~0 fuera de ventana (sin cambiar el mem_limit)
```

`docker/Dockerfile.backup` — **sin cambios** (el `ENTRYPOINT` sigue siendo `backup.sh`, útil para cualquier invocación standalone fuera de compose; el override vive enteramente en el compose file).

## Data Model

N/A — el marcador de salud es un archivo con timestamp (mtime), no un modelo de datos.

## API / Interface Contracts

- **Disparo diario**: `docker compose -f docker/docker-compose.backup.yml exec -T backup /usr/local/bin/backup.sh` (vía systemd timer, sin cambio de horario).
- **Estado del contenedor**: `docker compose -f docker/docker-compose.backup.yml ps` (o `make backup-status`) muestra `Up (healthy)`/`Up (unhealthy)` en todo momento, no solo durante una corrida.
- **Disparo manual**: `make backup` / `make backup-backup-run` — mismo efecto que el timer, contra el contenedor ya vivo.
- **Diagnóstico** (sin cambios): `docker compose -f docker/docker-compose.backup.yml run --rm --entrypoint restic backup -r <repo> snapshots|restore`.

## Dependencies

Ninguna — `stat`/`date`/`test`/`sleep` ya están en la imagen base (`postgres:16-alpine`), sin paquetes nuevos.

## Risks & Unknowns

- **Loop de reinicio si el `entrypoint:` override falla o se omite**: si por error el compose no overridea el entrypoint (o el override tiene un typo), el contenedor correría `backup.sh` como proceso principal, terminaría, y `restart: unless-stopped` lo reiniciaría en loop — corriendo backups sin parar. La verificación en `implement` debe confirmar explícitamente que el proceso en reposo es `sleep infinity` (`docker compose exec backup ps`) y que el contenedor **no** se reinició espontáneamente tras varios minutos arriba.
- **Umbral de 26h del healthcheck**: elegido con margen sobre el ciclo de 24h del timer; si el timer alguna vez corre más tarde de lo esperado (ej. el server estuvo apagado y `Persistent=true` lo compensa con demora), podría haber una ventana de falso `unhealthy`. Aceptable — es una señal de "revisar", no un estado destructivo.
- **`stat -c %Y` en Alpine**: busybox `stat` soporta `-c` en las versiones recientes de Alpine (confirmado en la imagen base ya usada, `postgres:16-alpine`), pero conviene confirmarlo con un chequeo real en `implement` en vez de asumirlo — si no está disponible, la alternativa es `find /backups/.last-success -mmin -1560` (busybox `find` con `-mmin`, igual de estándar).
- **Presupuesto de RAM**: el backup pasa de costar ~0 fuera de su ventana a pagar su footprint "Bajo" (~100MB) 24/7 — impacto menor comparado con lo que se aceptó para staging (B011), pero corresponde documentarlo en la tabla de `docs/infrastructure-design.md` igual que toda feature anterior.

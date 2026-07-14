---
name: backup-stable
code: SPEC-009
version: R00
date: 2026-07-13
status: Converged
---

# Spec: Stack `backup` siempre-arriba

## Summary

Convertir el contenedor de `backup` de efímero (`run --rm`, invisible entre corridas) a siempre-arriba (`restart: unless-stopped`), para que sea observable en todo momento por `monitoring` (cAdvisor/Prometheus) y tenga un healthcheck real que confirme si el último backup exitoso está fresco — sin cambiar qué hace `backup.sh` ni el mecanismo de disparo (sigue siendo systemd timer diario, ahora vía `docker compose exec` en vez de `run --rm`).

## User Stories

### US1 — El contenedor de backup es observable en todo momento (P1)

Como operador, quiero que el contenedor de `backup` esté siempre arriba, para que `cAdvisor`/`Prometheus` puedan trackear su consumo real de RAM en el tiempo y para tener una señal de "está vivo" incluso fuera de la ventana en la que corre el backup — hoy, si el contenedor efímero se rompe (falla el build, falla `docker compose run`), no queda ningún rastro visible entre una corrida y la siguiente.

**Acceptance Scenarios**:
- **Given** el stack `backup` levantado, **When** se inspecciona en cualquier momento del día (no solo durante una corrida), **Then** el contenedor `backup` aparece `Up`/`running` en `docker compose ps` y como target `up` en Prometheus (vía cAdvisor) — no solo durante los minutos en que corre `backup.sh`.
- **Given** un reinicio del server, **When** vuelve a estar arriba, **Then** el contenedor `backup` se levanta solo (`restart: unless-stopped`), sin intervención manual.
- **Given** el contenedor de backup siempre arriba, **When** se revisa su footprint en reposo (fuera de una corrida activa), **Then** su consumo de RAM es bajo (consistente con estar idle la mayor parte del día) — no paga el costo pico de una corrida activa (dump + chunking de restic) todo el tiempo.

### US2 — El disparo diario sigue siendo systemd, ahora contra un contenedor que ya existe (P1)

Como operador, quiero que el backup diario se siga disparando por el mismo timer de systemd de siempre, para no introducir un segundo mecanismo de scheduling — el contenedor ya no se crea y destruye en cada corrida, así que el timer pasa a ejecutar el script *dentro* del contenedor existente en vez de crear uno nuevo.

**Acceptance Scenarios**:
- **Given** el timer diario de systemd, **When** se dispara, **Then** ejecuta `backup.sh` dentro del contenedor `backup` ya corriendo (`docker compose exec`), no `docker compose run --rm` — el contenedor nunca se recrea para una corrida normal.
- **Given** que una corrida de `backup.sh` sigue en curso cuando el timer volvería a dispararse (ej. una corrida excepcionalmente larga), **When** ocurre, **Then** no se dispara una segunda corrida en paralelo — la propia semántica de `systemd` (`Type=oneshot` + timer) ya lo garantiza, sin necesidad de lógica de lock adicional en el script.
- **Given** el mecanismo de disparo, **When** se compara con cualquier otro scheduling recurrente de la infra (ej. el futuro refresh de staging), **Then** ambos usan systemd timers — ningún scheduler embebido en un contenedor (cron interno u otro), por el principio ya agregado a la constitución (R04).

### US3 — Healthcheck real: ¿el último backup exitoso está fresco? (P1)

Como operador, quiero que el estado de salud del contenedor refleje si el backup realmente está funcionando — no solo si el proceso sigue vivo — para enterarme por Prometheus/Grafana si el backup dejó de correr o de tener éxito, sin tener que ir a leer logs a mano.

**Acceptance Scenarios**:
- **Given** una corrida de `backup.sh` que termina exitosamente (los 2 repos restic — local y R2 — recibieron el snapshot), **When** termina, **Then** queda un marcador (ej. archivo con timestamp) registrando ese éxito.
- **Given** el contenedor `backup`, **When** Docker evalúa su `HEALTHCHECK`, **Then** el estado es `healthy` si el marcador existe y tiene menos de ~26h de antigüedad, y `unhealthy` si el marcador no existe o es más viejo que eso (el backup diario debería refrescarlo cada ~24h; 26h da margen sin ser laxo).
- **Given** que una corrida de `backup.sh` falla (ej. no llega a completar ninguno de los dos repos), **When** ocurre, **Then** el marcador **no** se actualiza — el healthcheck pasa a `unhealthy` en la ventana siguiente, visible en Prometheus como una señal real de que algo falló, no como ausencia de información.

## Edge Cases

- **Restart de Docker/reinicio del server durante una corrida activa** → la corrida en curso se interrumpe (igual que hoy); al volver a estar arriba el contenedor, el marcador de "último éxito" sigue reflejando la última corrida realmente exitosa (no se corrompe ni se marca falso positivo).
- **Primera vez que el contenedor arranca (nunca corrió un backup)** → sin marcador, el healthcheck debe ser `unhealthy` (o un estado neutral que no se confunda con "backup roto") hasta la primera corrida exitosa — no debe reportar `healthy` sin evidencia real.
- **El timer dispara mientras el contenedor está reiniciando/no disponible** (ej. tras un `docker compose restart backup` manual) → el `docker compose exec` falla esa corrida puntual; el healthcheck lo refleja en la ventana siguiente vía el marcador desactualizado — no hace falta manejo especial, es la misma semántica de "faltó una corrida" que un fallo de `backup.sh`.

## Explicit Non-Goals

- **No cambia qué hace `backup.sh`** — mismo `pg_dump -Fp` + filestore + restic (local + R2) + retención GFS. Esta feature es puramente sobre el ciclo de vida del contenedor y su observabilidad, no sobre el mecanismo de backup en sí.
- **No agrega protección contra solapamiento en el script** (ej. `flock`) — descartado explícitamente en la sesión de `/grilling`: systemd (`Type=oneshot` + timer) ya previene que se dispare una segunda corrida mientras la anterior sigue activa.
- **PITR / WAL archiving (B001)** — evaluado y descartado en la misma sesión de diseño; fuera de alcance, no se reconsidera acá.
- **No cambia el destino ni la retención de los backups** (Cloudflare R2 + copia local, GFS) — sin cambios.
- **No se toca `docker-compose.staging.yml` ni su ciclo de vida** — el refresh semanal de staging (B011) es una feature separada, aunque comparte el mismo principio de "systemd único" recién agregado a la constitución.

## Open Questions

Ninguna — el diseño quedó resuelto en la sesión de `/grilling` del 2026-07-13.

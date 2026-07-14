---
name: staging-stable
code: SPEC-010
version: R00
date: 2026-07-14
status: Converged
---

# Spec: Stack `staging` siempre-arriba con refresh semanal

## Summary

Convertir el stack `staging` de efímero (se levanta on-demand, auto-teardown a las ~3h) a siempre-arriba, con un refresh completo (restore del último backup de prod + anonimización, el mismo ciclo crítico de siempre) disparado automáticamente una vez por semana vía systemd timer — sin cambiar el mecanismo de restore/anonimización en sí, solo su ciclo de vida y cuándo se dispara.

## User Stories

### US1 — Staging siempre disponible, sin sesiones que expiren (P1)

Como QA, quiero que staging esté arriba en todo momento (no solo por una ventana de ~3h que puedo olvidar extender), para no tener que coordinar cuándo la levanto ni perder trabajo de QA en curso por un teardown automático a mitad de una sesión.

**Acceptance Scenarios**:
- **Given** el stack `staging` levantado, **When** pasan más de 3h, **Then** sigue arriba — no hay ningún teardown automático por tiempo transcurrido (el teardown de 3h existente se elimina).
- **Given** un reinicio del server, **When** vuelve a estar arriba, **Then** el stack `staging` se levanta solo (`restart: unless-stopped`), sin intervención manual — invierte el comportamiento actual (hoy el teardown al boot lo destruye incondicionalmente).
- **Given** el stack `staging`, **When** se inspecciona `docker compose ps`, **Then** aparece siempre observable por `monitoring` (cAdvisor/Prometheus), igual que el resto de los stacks permanentes.

### US2 — Refresh semanal automático, mismo ciclo crítico de siempre (P1)

Como operador, quiero que staging se refresque automáticamente una vez por semana con el último backup de prod anonimizado, para que nunca quede más vieja que ~7 días sin que yo tenga que dispararlo a mano — usando exactamente el mismo mecanismo de restore+anonimización ya construido en la feature 005, no uno nuevo.

**Acceptance Scenarios**:
- **Given** un systemd timer semanal, **When** se dispara, **Then** ejecuta `staging-up.sh` — el mismo script y el mismo orden crítico de siempre (teardown si ya está activa → restore → anonimización → recién ahí Odoo).
- **Given** que el timer se dispara mientras staging ya está arriba con datos de una corrida previa, **When** ocurre, **Then** el ciclo hace teardown + fresh restore (comportamiento ya existente de `staging-up.sh`, sin cambios) — nunca dos restores concurrentes, ni acumula estado entre corridas.
- **Given** el mismo mecanismo de disparo que el resto de la infra (backup diario, feature 009), **When** se compara, **Then** ambos usan systemd timers — ningún scheduler embebido en contenedor, por el principio ya agregado a la constitución (R04).
- **Given** que el refresh automático y un refresh manual (`make staging-up` / `staging-db-restore`) usan el mismo comando, **When** cualquiera de los dos corre, **Then** el resultado es idéntico — no hay una versión "automática" distinta de la manual.

### US3 — Pausar sin perder datos, destruir solo cuando es deliberado (P2)

Como operador, quiero poder pausar staging para liberar RAM temporalmente sin perder los datos del último refresh, y tener separado el camino para destruirla por completo cuando de verdad quiero un reset — para no tener que elegir entre "siempre arriba comiendo RAM" y "perder todo cada vez que la bajo un rato".

**Acceptance Scenarios**:
- **Given** staging levantada, **When** el operador corre `docker compose stop` sobre el stack, **Then** los contenedores se detienen pero los volúmenes (datos del último refresh) se conservan — un `docker compose up` posterior recupera el mismo estado, sin recorrer restore+anonimización de nuevo.
- **Given** staging levantada, **When** el operador corre `make staging-down` (o el target equivalente), **Then** sigue siendo destructivo (`down -v`) — decisión deliberada y manual, no automática, que borra los volúmenes.
- **Given** que el refresh semanal se dispara después de una pausa manual (`docker compose stop`), **When** ocurre, **Then** `staging-up.sh` la levanta con datos frescos igual que siempre (el script ya maneja el caso de "staging activa" con teardown + fresh restore).

## Edge Cases

- **El timer semanal se dispara mientras el operador tiene una sesión de QA en curso con datos cargados a mano** → se pisan (comportamiento ya existente y aceptado de `staging-up.sh`: cualquier refresh es teardown + fresh restore completo, sin preservar cambios manuales — la cadencia semanal, no diaria, es la mitigación deliberada de este trade-off, ver Non-Goals).
- **El server se reinicia mientras staging está con datos de un refresh reciente pero sin estar "activa" en ese momento (pausada manualmente)** → al volver, `restart: unless-stopped` la levanta con los últimos datos conservados — no dispara un refresh nuevo por sí solo, el timer semanal sigue su propio calendario.
- **El timer semanal se dispara mientras un backup de prod (feature 009) está en curso** → `staging-up.sh` restaura del *último snapshot completo* disponible en el repo restic (el mismo comportamiento actual, restic solo expone snapshots completos, nunca uno a medio escribir).
- **`staging-extend.sh` y el timer transiente de 3h dejan de existir** → cualquier referencia/target que los invocaba se elimina; no hay reemplazo, porque ya no hay sesión que "extender".

## Explicit Non-Goals

- **No cambia el mecanismo de restore ni de anonimización** — `staging-up.sh`, `restore-staging.sh`, `anonymize-staging.sql` siguen siendo la misma lógica, sin tocar. Esta feature es sobre *cuándo* se dispara el ciclo y si el stack sobrevive entre corridas, no sobre *cómo* funciona el ciclo en sí.
- **No agrega preservación de cambios manuales entre refreshes** — cada refresh (manual o automático) sigue siendo un reset completo a los datos de prod anonimizados más recientes. Si se necesita persistencia de datos de prueba entre refreshes, es una feature aparte.
- **No cambia el aislamiento de red de staging** (`staging-net`, separada de `odoo-shared`) ni el ruteo de Traefik — sin cambios.
- **No cambia el sizing de staging** (`mem_limit`/`shared_buffers`/workers) — el margen de RAM más ajustado que resulta de estar siempre-arriba ya fue evaluado y aceptado explícitamente en la sesión de `/grilling` que originó este backlog item, dentro de los 14 GiB actuales del server.
- **No agrega un target `staging-stop`** — pausar sin perder datos es `docker compose stop` directo (decisión explícita del usuario en `/grilling`); no hace falta un target dedicado del Makefile para esto.

## Open Questions

Ninguna — el diseño quedó resuelto en la sesión de `/grilling` del 2026-07-13.

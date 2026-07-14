---
name: staging
code: SPEC-005
version: R01
date: 2026-07-12
status: Converged
---

# Spec: Stack `staging` efímero

## Summary

Un entorno de staging efímero que levanta on-demand una réplica fiel de producción a menor escala, siempre restaurando el último backup de prod y anonimizándolo **antes** de arrancar Odoo, expuesto en `staging.miempresa.com`, y que se autodestruye (`down -v`) tras ~3h para no comprometer la RAM de prod.

## Clarifications

### Session 2026-07-12

- Q: Al pedir levantar staging cuando ya está activa → A: Teardown + fresh restore (baja con `down -v` y hace un ciclo nuevo completo: restore del último backup + anonimización + up). Staging siempre refleja el prod más reciente; una sesión de QA en curso se pisa sin aviso (aceptable por ser de uso individual/puntual).
- Q: Aislamiento de red prod↔staging vs. ruteo de Traefik a ambos → A: Traefik puentea las dos redes. Staging vive en su propia red aislada; su Odoo no toca `odoo-shared`, así no puede resolver ni alcanzar la `db`/`pgbouncer` de prod (honra el principio de "redes aisladas entre entornos" de la constitución). Traefik se une a ambas redes para rutear — el stack `edge` se modifica para agregar la red de staging.
- Q: Reinicio del server con staging activa → A: Teardown en el boot. Un servicio oneshot al arrancar el server hace `down -v` de staging incondicionalmente — staging nunca sobrevive un reinicio (sus datos son descartables, se restauran de backup). El operador la vuelve a levantar explícitamente si la necesita.

## User Stories

### US1 — Restaurar y anonimizar antes de arrancar Odoo (P1)

Como operador, quiero que staging levante con datos reales de prod pero anonimizados, y que Odoo **nunca** arranque con datos de prod sin anonimizar, para no disparar emails/pagos/webhooks reales a clientes.

**Acceptance Scenarios**:
- **Given** un backup de prod disponible en el repo restic, **When** se levanta staging, **Then** el orden de operaciones es estricto: (1) restore de DB + filestore, (2) SQL de anonimización, (3) recién ahí arranca el contenedor Odoo — nunca Odoo antes del paso 2.
- **Given** que el paso de anonimización falla, **When** ocurre, **Then** staging aborta sin arrancar Odoo (exit ≠ 0), dejando la DB restaurada pero sin un Odoo vivo sobre datos sin anonimizar.
- **Given** staging ya levantada, **When** se inspecciona la DB, **Then** los servidores de correo saliente están desactivados (`ir_mail_server.active = false`), los emails de `res_partner` reescritos a `staging+<id>@example.com`, los passwords de usuarios reseteados a valores random, los payment providers deshabilitados, las URLs de webhooks limpiadas en `ir_config_parameter`, y los crons de mail desactivados.

### US2 — Réplica fiel de prod a menor escala (P1)

Como QA, quiero que staging se comporte como prod (mismo modelo multiproceso, mismo ruteo de longpolling), no como un modo de ejecución distinto, para que lo que valido en staging sea representativo.

**Acceptance Scenarios**:
- **Given** staging levantada, **When** se inspecciona su `odoo-staging.conf`, **Then** corre con workers (multiproceso), sin `dev_mode`/hot-reload, con `db_name = odoo_staging` — idéntico modelo que prod salvo el sizing reducido (1 worker, `limit_memory_hard=682 MiB`) y `shared_buffers=512 MiB`.
- **Given** staging expuesta, **When** un cliente WebSocket se conecta a `/websocket`, **Then** se rutea al puerto de longpolling (8072), igual que en prod; el resto del tráfico va a 8069.

### US3 — Exposición externa por el edge existente (P2)

Como QA remoto, quiero acceder a staging por `staging.miempresa.com` sin publicar puertos ni usar SSH, reutilizando el edge stack de prod.

**Acceptance Scenarios**:
- **Given** staging levantada y el edge stack corriendo, **When** se navega a `https://staging.miempresa.com/web/health`, **Then** responde `200` a través de `cloudflared → Traefik → odoo staging`, sin que staging publique ningún puerto al host.
- **Given** staging apagada, **When** se navega a `staging.miempresa.com`, **Then** Traefik responde con un error de servicio no disponible (no un crash del edge) — el router existe pero su backend está caído.
- **Given** staging levantada en su red aislada, **When** el Odoo de staging intenta resolver `db`/`pgbouncer` de prod, **Then** no los alcanza (staging no está en `odoo-shared`) — solo Traefik puentea ambas redes, los servicios de datos de cada entorno quedan aislados entre sí.

### US4 — Teardown duro auto-forzado (P1)

Como operador, quiero que staging se autodestruya sí o sí tras ~3h aunque me olvide de bajarla, con opción de extender, para que nunca quede colgada comiendo RAM que prod necesita.

**Acceptance Scenarios**:
- **Given** staging levantada, **When** pasan ~3h desde el arranque, **Then** un timer dispara `down -v` automáticamente, destruyendo los volúmenes de staging, corra o no el operador algún comando.
- **Given** staging levantada, **When** el operador ejecuta el comando de extensión, **Then** el timer de teardown se reprograma ~3h hacia adelante.
- **Given** staging bajada (manual o por timer), **When** se inspeccionan los volúmenes, **Then** los volúmenes de datos de staging fueron destruidos (`down -v`) — no queda estado persistente entre corridas.

### US5 — `postgres-exporter` nace y muere con staging (P3)

Como operador de monitoring, quiero que el exporter de Postgres de staging viva en el stack de staging, no en el de monitoring, para que no quede como target fallando cuando staging está abajo.

**Acceptance Scenarios**:
- **Given** el stack de staging definido, **When** se inspecciona `docker-compose.staging.yml`, **Then** incluye el servicio `postgres-exporter` (no está en `docker-compose.monitoring.yml`).
- **Given** staging bajada, **When** Prometheus scrapea, **Then** el exporter de staging no existe como proceso (arrancó y murió con staging), sin generar un target permanentemente caído.

## Edge Cases

- **No hay backup previo (repo restic vacío o inaccesible)**: el arranque de staging aborta con un error claro antes de tocar nada, sin dejar un entorno a medio levantar.
- **El restore falla a mitad**: staging aborta sin correr la anonimización ni arrancar Odoo.
- **Staging ya está levantada y se pide levantarla de nuevo**: teardown + fresh restore — se baja (`down -v`) y se corre un ciclo nuevo completo (restore + anonimización + up), pisando cualquier sesión en curso.
- **El server se reinicia con staging activa**: al volver, un servicio oneshot de boot hace `down -v` de staging incondicionalmente — staging nunca sobrevive un reinicio; el operador la vuelve a levantar si la necesita.
- **Anonimización parcialmente aplicada** (algunas tablas sí, otras no, por un error a mitad): se trata como fallo total — Odoo no arranca (US1).

## Explicit Non-Goals

- **No hay staging "siempre arriba"** — es efímera por definición; no se soporta un modo persistente.
- **No `dev_mode` / hot-reload** — staging es réplica fiel de prod, no un entorno de desarrollo.
- **No restore desde R2** — staging restaura desde el repo restic **local** (`/backups/restic`, en el server, rápido); R2 es solo para disaster recovery, no para el refresh rutinario de staging.
- **No Makefile todavía** — la orquestación de staging (up/extend/down) se entrega como script(s) versionado(s), operados con comandos directos; el Makefile (feature separada, roadmap #6) los envolverá después sin duplicar lógica.
- **No anonimización configurable por entorno** — el conjunto de reglas de anonimización es fijo y exhaustivo respecto de todo lo que pueda producir efectos externos (mail, pagos, webhooks, crons).
- **No cambia el flujo de backup** (feature 004) — staging es consumidor del backup, no lo modifica.

## Open Questions

- Ninguna pendiente.

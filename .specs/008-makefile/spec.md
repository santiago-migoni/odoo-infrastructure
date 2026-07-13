---
name: makefile
code: SPEC-008
version: R00
date: 2026-07-13
status: Converged
---

# Spec: Makefile — interfaz operativa única

## Summary

Un `Makefile` en la raíz del repo que se convierte en la única interfaz operativa de los 5 stacks (convención `<stack>-<service>-<action>` + targets compuestos de stack), envolviendo los comandos `docker compose` y los scripts que ya existen — sin duplicar lógica — más un restore de prod nuevo (DB+filestore desde el repo restic, con guard `CONFIRM=yes`) para que el target de disaster recovery que la documentación ya promete sea real y probado.

## Clarifications

### Session 2026-07-13

- Q: Fuente del restore de prod (local / R2 / default+flag) → A: R2 por defecto (off-site, cubre la pérdida del server/disco entero — el caso que justifica disaster recovery), con flag `LOCAL=yes` para forzar el repo local (rápido, sin red, cuando el disco está sano). Ambos escenarios cubiertos: `make prod-db-restore CONFIRM=yes` → R2; `make prod-db-restore CONFIRM=yes LOCAL=yes` → local.
- Q: Alcance de la enumeración de targets → A: Todas las combinaciones stack×servicio×acción de la tabla de diseño (`infrastructure-design.md`), respetando la aplicabilidad por acción (up/stop/restart/logs para todos los servicios; `rebuild` solo servicios con build propio; `pull` solo imágenes oficiales; `restore` solo `db`; `run` solo `backup`) — set completo y regular, no solo el subconjunto documentado en CLAUDE.md.

## User Stories

### US1 — Un solo lugar para operar cualquier stack (P1)

Como operador, quiero correr cualquier operación de cualquier stack con `make <stack>-<servicio>-<acción>` (y targets compuestos por stack), en vez de recordar rutas largas de `docker compose -f Docker/docker-compose.<stack>.yml ...` o qué script correr, para no memorizar comandos ni equivocarme de ruta tras la reorg 007.

**Acceptance Scenarios**:
- **Given** el `Makefile` en la raíz, **When** se corre `make prod-odoo-logs` (o cualquier `<stack>-<servicio>-<acción>` documentado), **Then** ejecuta la operación equivalente contra `Docker/docker-compose.prod.yml` — mismo efecto que el comando `docker compose` a mano, sin que el operador escriba la ruta.
- **Given** los nombres de target que CLAUDE.md ya publicita (`prod-up`, `prod-odoo-rebuild`, `prod-odoo-logs`, `staging-up`, `staging-down`, `edge-traefik-restart`, `monitoring-grafana-up`, `backup-backup-run`, `prod-db-restore`), **When** se inspecciona el `Makefile`, **Then** cada uno existe con ese nombre exacto — la documentación y el Makefile no divergen.
- **Given** las operaciones que ya viven en scripts (`staging-up.sh`, `staging-down.sh`, `staging-extend.sh`, `setup-backup-role.sh`, `setup-monitoring-role.sh`), **When** el target correspondiente se ejecuta, **Then** invoca el script existente — **no** reimplementa su lógica en el Makefile (honra "nunca lógica duplicada entre script y Makefile" de la constitución).
- **Given** la tabla de diseño (`infrastructure-design.md`) de stacks×servicios×acciones, **When** se inspecciona el `Makefile`, **Then** existe un target para cada combinación válida (up/stop/restart/logs para todo servicio; `rebuild` solo donde hay build propio; `pull` solo imágenes oficiales; `restore` solo `db`; `run` solo `backup`) — set completo y regular, no solo los publicitados en CLAUDE.md.
- **Given** el `Makefile`, **When** se corre `make` sin argumentos (o `make help`), **Then** lista los targets disponibles con una descripción corta — el universo de comandos es descubrible sin leer el archivo.

### US2 — Restore de prod como disaster recovery seguro (P1)

Como operador, quiero poder restaurar la DB + filestore de producción desde un backup restic con `make prod-db-restore CONFIRM=yes`, para tener un camino de disaster recovery real y probado — hoy solo existe el restore de staging.

**Acceptance Scenarios**:
- **Given** un backup de prod disponible en R2, **When** se corre `make prod-db-restore CONFIRM=yes`, **Then** la DB de prod y su filestore quedan restaurados juntos (uno sin el otro deja el restore incompleto, principio de la constitución) al estado del último snapshot de R2 (fuente por defecto — off-site, cubre la pérdida del server).
- **Given** que el disco/repo local está sano y se busca velocidad, **When** se corre `make prod-db-restore CONFIRM=yes LOCAL=yes`, **Then** restaura del repo restic local en vez de R2 — mismo resultado, sin depender de la red.
- **Given** el target destructivo, **When** se corre `make prod-db-restore` **sin** `CONFIRM=yes`, **Then** aborta sin tocar nada y explica que hace falta la confirmación explícita — no es invocable por error.
- **Given** que el restore sobrescribe datos reales de producción, **When** corre, **Then** el orden de operaciones garantiza que Odoo no está sirviendo sobre una DB a medio restaurar (Odoo parado durante el restore, reiniciado al terminar).
- **Given** que el restore falla a mitad de camino, **When** ocurre, **Then** el target sale con código ≠ 0 y no deja Odoo arrancado sobre datos inconsistentes.

### US3 — CI puede reusar los mismos targets el día de mañana (P2)

Como responsable del pipeline futuro (feature de CI/CD, aún sin planificar), quiero que la lógica operativa viva enteramente en el Makefile, para que cuando exista el pipeline no haya que duplicar comandos de deploy entre un script/YAML y el uso manual.

**Acceptance Scenarios**:
- **Given** el `Makefile`, **When** se revisa cualquier target de ciclo de vida o deploy, **Then** no hay lógica operativa que solo exista fuera del Makefile y tendría que reescribirse en un YAML de pipeline — el Makefile es la fuente única (los scripts que invoca son compartibles por CI vía los mismos targets).

## Edge Cases

- **`CONFIRM` con un valor distinto de `yes`** (`CONFIRM=si`, `CONFIRM=YES`, vacío) → se trata como no confirmado; solo `CONFIRM=yes` exacto procede.
- **Target de un servicio que no aplica a ese stack** (ej. `rebuild` en un servicio de imagen oficial, que no tiene build propio) → no se define ese target, o falla con un mensaje claro — no ejecuta algo sin sentido.
- **`make` corrido desde un subdirectorio** → los targets asumen la raíz del repo como cwd (donde `Docker/`, `env/`, `config/`, `scripts/` resuelven); documentado, igual que hoy con los comandos directos.
- **Restore de prod con Odoo ya parado / stack caído** → el target es idempotente respecto al estado de Odoo (lo para si está arriba, no falla si ya estaba parado).
- **Colisión con la reorg 007** → los targets usan las rutas nuevas (`Docker/docker-compose.<stack>.yml`, `env/.env.<stack>`, nombres de proyecto `odoo-infrastructure-<stack>`) — nunca las viejas.

## Explicit Non-Goals

- **CI/CD entero** (GitHub Actions, runner self-hosted, deploys automáticos a staging, deploys manuales a prod, approval gates, rollback, backup pre-deploy, selective module update) — queda como feature aparte, sin planificar en este spec. Este Makefile es su prerequisito, no su implementación.
- **No se reimplementa la lógica de los scripts existentes** — el Makefile los envuelve; `staging-up.sh` y compañía siguen siendo la fuente de esa lógica.
- **No se cambia el comportamiento de ningún stack** — mismos comandos `docker compose`, mismas imágenes, mismo sizing; solo se les pone una fachada uniforme.
- **No se toca la reorg de 007** ni se mueven archivos — el Makefile referencia el layout actual tal cual.
- **Restore de staging** — ya existe (`staging-db-restore` / `staging-up.sh`), solo se le pone target; no se re-especifica.

## Open Questions

Ninguna — ambas resueltas en la sesión de clarificación.

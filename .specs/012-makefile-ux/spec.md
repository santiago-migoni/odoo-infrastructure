---
name: makefile-ux
code: SPEC-012
version: R00
date: 2026-07-14
status: Converged
---

# Spec: Makefile UX — Comandos Descubribles

## Summary

Reemplazar la convención de targets `<stack>-<service>-<action>` por `<verbo>-<stack>[-<servicio>]`, con un dispatcher único que garantiza que ningún comando escrito a medias o mal termine en un error mudo de `make`, para que el operador encuentre y ejecute el comando correcto sin tener que memorizarlo de antemano.

## User Stories

### US1 — Verbo desnudo como menú (P1)

Hoy, tipear un comando incompleto (`make down`) falla con `No rule to make target`. El operador no sabe qué combinaciones existen sin abrir el `Makefile` o `make help` y traducir mentalmente una plantilla (`<stack>-down`) a un comando real.

**Acceptance Scenarios**:
- **Given** el operador no recuerda el nombre exacto de un comando, **When** tipea solo el verbo (`make down`), **Then** ve un menú con cada combinación válida de ese verbo (`down-prod`, `down-staging`, `down-edge`, `down-monitoring`, `down-backup`), concreta y copiable — no una plantilla.
- **Given** un verbo de mantenimiento no uniforme (`make pull`), **When** se tipea solo, **Then** el menú lista únicamente las combinaciones que tienen sentido (imágenes oficiales), sin incluir servicios de build propio.
- **Given** cualquier verbo tipeado solo, **When** se ejecuta, **Then** no se dispara ninguna acción sobre ningún contenedor — el verbo desnudo siempre es de solo lectura (muestra, nunca actúa).

### US2 — Combinación inválida guía al comando correcto (P1)

Hoy una combinación que no tiene target generado (ej. pedir `pull` sobre un servicio de build propio, o `rebuild` sobre un servicio de imagen oficial) también falla con el mismo error mudo de Make, indistinguible de un typo.

**Acceptance Scenarios**:
- **Given** el operador pide `pull` sobre un servicio que se construye en este repo (ej. intenta `pull-prod-odoo`), **When** ejecuta el comando, **Then** ve un mensaje que explica que ese servicio no tiene imagen oficial y sugiere el comando correcto (`rebuild-prod-odoo`) — no `No rule to make target`.
- **Given** el operador pide `rebuild` sobre un servicio de imagen oficial (ej. `rebuild-prod-db`), **When** ejecuta el comando, **Then** ve un mensaje equivalente sugiriendo `pull-prod-db`.
- **Given** un stack o servicio que no existe (typo, ej. `up-produ`), **When** se ejecuta, **Then** el mensaje de error lista los stacks/servicios reales disponibles para ese verbo, no un error genérico de Make.

### US3 — `down` es seguro en todos los stacks (P1)

Hoy `staging-down` baja **y destruye volúmenes** (`down -v`), mientras `prod-down` baja conservando datos — mismo verbo, comportamiento opuesto, sin ninguna señal en el nombre.

**Acceptance Scenarios**:
- **Given** cualquier stack (`prod`, `staging`, `edge`, `monitoring`, `backup`), **When** se ejecuta `down-<stack>`, **Then** el stack baja y sus volúmenes/datos persistentes quedan intactos, sin excepción.
- **Given** que se necesita borrar los volúmenes de staging (único caso real hoy), **When** se ejecuta, **Then** el comando es `nuke-staging` — nombre propio, no una variante del verbo `down`.
- **Given** el menú del verbo desnudo `make nuke` (si se tipea), **When** se muestra, **Then** lista únicamente `nuke-staging` — no existe `nuke-prod` ni un `nuke` genérico aplicable a cualquier stack.

### US4 — Comandos de tarea con nombre propio, agrupados aparte (P2)

Los comandos que no son "verbo aplicado a un stack/servicio" sino procedimientos únicos (correr un backup, refrescar staging, disaster recovery) hoy están mezclados en el mismo namespace y a veces son alias ambiguos o silenciosos.

**Acceptance Scenarios**:
- **Given** el operador quiere correr un backup ahora, **When** ejecuta `make run-backup`, **Then** corre el job de backup dentro del contenedor ya levantado; `make up-backup` (levantar el contenedor) es un comando distinto y no ambiguo con este.
- **Given** el operador quiere refrescar staging, **When** ejecuta `make refresh-staging`, **Then** corre el ciclo completo (restore del último backup de prod → anonimización → up) — el mismo invariante crítico de siempre.
- **Given** el operador intenta `make restore-staging` (nombre del alias viejo), **When** lo ejecuta, **Then** ve un mensaje que explica que staging nunca se restaura parcial (Odoo no puede arrancar con datos de prod sin anonimizar) y lo dirige a `refresh-staging` — no ejecuta nada en nombre de ese alias.
- **Given** el operador necesita disaster recovery de prod, **When** ejecuta `make restore-prod`, **Then** exige `CONFIRM=yes` explícito (con `LOCAL=yes` opcional para forzar el repo local) — mismo guard que existe hoy.
- **Given** el operador tipea `make help`, **When** lo ejecuta, **Then** ve dos secciones diferenciadas: STACKS (grilla concreta verbo-stack, con el listado de servicios de referencia) y TAREAS (comandos con nombre propio, con el `make` completo ya que se copian enteros).

### US5 — Vista unificada del estado de los 5 stacks (P2)

Hoy no existe una forma de ver el estado de todo el repo de una — solo `ps-<stack>` uno por uno.

**Acceptance Scenarios**:
- **Given** el operador quiere saber qué está corriendo en todo el repo, **When** ejecuta `make ps` (verbo desnudo, sin stack), **Then** ve una tabla con columnas `STACK | SERVICIO | ESTADO` para los 5 stacks juntos — no 5 bloques nativos de `docker compose ps` con headers repetidos.
- **Given** un stack está completamente abajo, **When** aparece en la tabla de `make ps`, **Then** se indica claramente (ej. "— stack abajo —"), no se omite silenciosamente.

## Edge Cases

- El servicio `backup` (stack `backup`, build propio vía `Dockerfile.backup`) no tiene hoy target de `rebuild` — se agrega `rebuild-backup-backup` bajo la convención nueva, cerrando ese hueco preexistente.
- Los scripts invocados por las tareas (`staging-up.sh`, `staging-down.sh`, `prod-db-restore.sh`) se renombran a `refresh-staging.sh`, `nuke-staging.sh`, `restore-prod.sh` respectivamente — mismo contenido/lógica interna, solo el nombre de archivo y las referencias a él (incluyendo `ExecStart=` en los `systemd` units correspondientes).
- El prefijo de log ya existente en esos scripts (`[staging-up] ...`) se actualiza para coincidir con el nuevo nombre de comando (`[refresh-staging] ...`), para que lo que el operador tipeó y lo que el script anuncia sean la misma palabra.
- `systemd` (`odoo-backup.service`, `staging-refresh.service`) sigue invocando los scripts renombrados directamente — nunca pasa por `make` ni por el dispatcher. Ya documentado como excepción deliberada en la constitución (R06); este spec solo actualiza las rutas de `ExecStart=` al nuevo nombre de archivo.

## Explicit Non-Goals

- No se modifica la lógica interna de ningún script de tarea (`backup.sh`, el contenido funcional de `refresh-staging.sh`/`nuke-staging.sh`/`restore-prod.sh` más allá del rename) — el comportamiento real de backup/restore/refresh no cambia, solo cómo se invoca.
- No se modifica ningún `docker-compose.*.yml` — ni servicios, ni healthchecks, ni recursos.
- No se arregla `scripts/next-feature-number.sh` (no escanea `.specs/archive/`) — es un hallazgo aparte, anotado para el backlog, no bloquea este spec.
- No se hace que `systemd` pase a invocar `make`/el dispatcher — decisión ya cerrada en la constitución R06.
- No se agrega color/ANSI a la salida de los comandos en este spec — la tabla de `make ps` y los mensajes guiados son texto plano; color queda como posible iteración futura si hace falta.

## Open Questions

Ninguna — todas las decisiones de diseño se cerraron en la sesión de `/grilling` previa a este spec.

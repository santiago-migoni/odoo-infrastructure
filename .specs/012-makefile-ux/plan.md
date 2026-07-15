---
name: makefile-ux
code: PLAN-012
version: R00
date: 2026-07-14
---

# Plan: Makefile UX — Comandos Descubribles

## Approach

El `Makefile` se reduce a un `.DEFAULT_GOAL := help` más una única regla catch-all (`%:`) que delega todo target invocado a un dispatcher en shell (`scripts/mk-dispatch.sh`), que es la única fuente de verdad para: mapear `<verbo>-<stack>[-<servicio>]` al comando `docker compose` real, mostrar el menú cuando falta información, y guiar cuando la combinación es inválida. Las tareas con nombre propio (`run-backup`, `refresh-staging`, etc.) se resuelven en el mismo dispatcher como casos literales, sin parsear verbo/stack/servicio.

## Constitution Check

- **Naming Conventions**: implementa exactamente `<verbo>-<stack>[-<servicio>]` de R06 — verbos de grilla uniformes, verbos de mantenimiento no uniformes, `nuke` como comando único no genérico. Alineado.
- **Code Principles**: "ningún comando termina en error mudo de make" y "un solo dispatcher como fuente única de verdad" son R06 — este plan es la implementación directa de esos dos principios. `down` nunca destructivo — el dispatcher nunca pasa `-v` a `docker compose down`.
- **Excepción systemd**: `systemd` sigue invocando scripts directo, nunca `make`/el dispatcher — solo se actualizan las rutas `ExecStart=` a los nombres de archivo nuevos, la mecánica de disparo no cambia.
- **Tech stack**: no agrega dependencias — `sh` + `docker compose`, ya en uso en todo el repo.

## Architecture

**Makefile** (~15 líneas): sin macros que generen targets. Dos reglas: `help` (target real, para que `make help` sea explícito y no dependa del catch-all) y `%:` (catch-all, para cualquier otro nombre). Ambas delegan al dispatcher pasando `$@` como el nombre de target invocado. Las asignaciones de variable en línea de comando (`make restore-prod CONFIRM=yes`) ya se auto-exportan al entorno del recipe — el dispatcher las lee como variables de entorno (`$CONFIRM`, `$LOCAL`), igual que hoy leen los scripts.

**Dispatcher** (`scripts/mk-dispatch.sh`): recibe el nombre de target como único argumento. Lógica en dos fases:

1. **Match literal primero** — contra la tabla fija de comandos de TAREAS (`run-backup`, `refresh-staging`, `restore-prod`, `nuke-staging`, `setup-backup-role`, `setup-monitoring-role`) y los alias retirados que deben explicar en vez de fallar (`restore-staging`, `backup`). Si matchea, ejecuta o explica, termina ahí.
2. **Parseo `<verbo>-<stack>[-<servicio>]`** si no matcheó nada literal:
   - **Verbo** = el segmento antes del primer `-`, contra la tabla fija de verbos (`up`, `stop`, `down`, `ps`, `logs`, `restart`, `pull`, `rebuild`). Los verbos nunca tienen guiones, así que esto es inambiguo.
   - Si no queda nada después del verbo (target == verbo exacto) → **verbo desnudo**: `ps` corre la tabla global (única excepción de solo-lectura que sí actúa); cualquier otro verbo imprime el menú de combinaciones válidas para ese verbo y termina sin tocar contenedores.
   - **Stack** = buscar cuál de los 5 stacks conocidos (`prod`, `staging`, `edge`, `monitoring`, `backup`) es el resto completo, o un prefijo de él seguido de `-` (esto resuelve la ambigüedad de servicios con guión propio, ej. `postgres-exporter-prod`, sin adivinar por posición de guión).
   - **Servicio** (opcional) = lo que queda después de `<stack>-`, validado contra la lista de servicios real de ese stack (misma lista que hoy vive en el `Makefile`, movida al dispatcher).
   - Con verbo+stack[+servicio] resueltos, valida la combinación (¿`down` con servicio? ¿`pull`/`rebuild` contra el tipo de build correcto?) y o ejecuta el `docker compose` real, o imprime el error guiado.

**Tabla verbo → docker compose:**

| Verbo | Nivel stack | Nivel servicio | Comando |
|---|---|---|---|
| `up` | sí | sí | `up -d [servicio]` |
| `stop` | sí | sí | `stop [servicio]` |
| `down` | sí | **no** (error guiado → sugiere `stop-<stack>-<servicio>`) | `down` (nunca `-v`) |
| `ps` | sí | sí | `ps [servicio]` |
| `logs` | sí | sí | `logs -f [servicio]` |
| `restart` | no* | sí | `restart <servicio>` |
| `pull` | no* | sí, solo imagen oficial | `pull <servicio>` |
| `rebuild` | no* | sí, solo build propio | `build --no-cache <servicio> && up -d <servicio>` |

\* Igual que hoy: sin variante agregada a nivel stack — no se inventa alcance nuevo no pedido por el spec.

**Tabla de build propio** (para validar `pull`/`rebuild`): `prod/odoo`, `staging/odoo-staging`, `backup/backup`. Todo lo demás es imagen oficial.

**`make ps` global** (US5): el dispatcher corre `docker compose -f docker/docker-compose.<stack>.yml ps --format json` por cada uno de los 5 stacks, y renderiza una tabla propia `STACK | SERVICIO | ESTADO` a partir del JSON — si un stack no tiene contenedores corriendo, la fila dice `— stack abajo —` en vez de omitirse.

## File Structure

```text
Makefile                              ← reescrito: ~15 líneas, help + catch-all, sin macros
scripts/
├── mk-dispatch.sh                    ← nuevo — el dispatcher, única fuente de verdad
├── refresh-staging.sh                ← renombrado de staging-up.sh (mismo contenido)
├── nuke-staging.sh                   ← renombrado de staging-down.sh (mismo contenido)
│                                        (los 2: solo se actualiza el prefijo de log,
│                                         ej. "[staging-up]" → "[refresh-staging]")
├── prod-db-restore.sh                ← sin cambios de nombre — "restore-prod.sh" ya existe como
│                                        worker interno (equivalente a restore-staging.sh); el
│                                        comando `restore-prod` delega a este archivo tal cual
└── backup.sh                         ← sin cambios (invocado por nombre de archivo, no por target)
systemd/
└── staging-refresh.service           ← ExecStart= apunta a refresh-staging.sh
CLAUDE.md                             ← ejemplos de comandos actualizados a la convención nueva
README.md                             ← ídem
INSTALL.md                            ← ídem
.specs/backlog.md                     ← nuevo item: scripts/next-feature-number.sh no escanea
                                         .specs/archive/ (hallazgo de esta sesión, fuera de alcance)
```

`docker-compose.*.yml`, `Dockerfile*`, `odoo-backup.service` y `backup.sh`: sin cambios.

## Data Model

N/A (no hay entidades persistentes — el "modelo de datos" son las tablas estáticas de verbos/stacks/servicios/build-type descritas arriba, que viven como `case`/variables dentro del dispatcher).

## API / Interface Contracts

**Contrato del dispatcher**: `scripts/mk-dispatch.sh <target-name>` — recibe exactamente el string que el usuario tipeó después de `make` (ej. `down-prod-odoo`, `ps`, `restore-prod`). Variables de entorno relevantes (`CONFIRM`, `LOCAL`) llegan ya exportadas por Make, no como argumentos. Código de salida: `0` en éxito o en menú/ayuda mostrado; no-cero si la acción subyacente (`docker compose ...`) falla o si el guard de una tarea destructiva no se cumple (mismo comportamiento que hoy en `prod-db-restore.sh`).

**Contrato del Makefile**: cualquier `make <lo-que-sea>` que no sea `help` se reduce a `scripts/mk-dispatch.sh <lo-que-sea>` vía la regla `%:`. El Makefile no vuelve a tener conocimiento de qué combinaciones son válidas — esa es responsabilidad exclusiva del dispatcher.

## Dependencies

Ninguna nueva — `sh`, `docker`, `docker compose` (ya usados en `scripts/*.sh` existentes). El parseo de `docker compose ps --format json` usa el JSON que Docker Compose ya expone nativamente (no requiere `jq`; se puede extraer con herramientas POSIX o, si simplifica mucho el código, agregar `jq` — a decidir en `/tasks` si el parseo a mano resulta demasiado frágil).

## Risks & Unknowns

- **Regla catch-all `%:` de Make**: es un idiom conocido pero exige que ningún archivo/directorio real del repo se llame igual que un target posible (ej. no puede existir un archivo llamado `up` en la raíz) — ya se verificó que no hay colisiones hoy; si se agrega alguno en el futuro, Make preferiría el archivo sobre la regla catch-all silenciosamente. Vale la pena un check de esto en `/implement`.
- **Parseo de `docker compose ps --format json`**: el formato exacto (una línea JSON por contenedor vs. un array) varía levemente entre versiones de Compose — confirmar contra la versión real instalada durante `/implement`, no asumir.
- `scripts/next-feature-number.sh` no escanea `.specs/archive/` — confirmado como hallazgo, no se arregla acá (non-goal explícito), pero se documenta en el backlog para no perderlo.

---
name: makefile
code: PLAN-008
version: R00
date: 2026-07-13
---

# Plan: Makefile — interfaz operativa única

## Approach

Un `Makefile` en la raíz con una variable `COMPOSE_<stack>` por stack (`docker compose -f Docker/docker-compose.<stack>.yml`) y un template `$(eval $(call ...))` que genera las combinaciones regulares `<stack>-<servicio>-<acción>` (up/stop/restart/logs para cada servicio; rebuild solo donde hay build propio; pull solo imágenes oficiales) sin escribir ~60 líneas a mano. Los targets especiales/compuestos (ciclo de staging, backup, restore de prod, alta de roles, `<stack>-up/down/status`) se escriben explícitos y **llaman a los scripts que ya existen** — el Makefile no reimplementa lógica. La única capacidad nueva es el restore de prod: dos scripts nuevos (`prod-db-restore.sh` orquestador de host + `restore-prod.sh` que corre dentro de la imagen `Dockerfile.backup`), que espejan el patrón de staging (005) pero contra la DB `odoo` real, sin anonimización, con guard `CONFIRM=yes` y fuente R2 por defecto / `LOCAL=yes` opcional.

## Constitution Check

- **Tech stack**: sin dependencias nuevas. `make` (GNU Make, ya presente en cualquier host Linux/macOS). Reusa `Docker/docker-compose.*.yml`, `env/.env.*`, `scripts/*.sh`, la imagen `Docker/Dockerfile.backup` — todo del layout 007.
- **Code principles aplicables**:
  - "El Makefile es la única interfaz operativa a partir de esta feature, compartida entre uso manual y CI, nunca lógica duplicada entre script y pipeline" → **esta feature entrega justamente eso**; los targets envuelven `docker compose` + scripts, la lógica vive en los scripts. ✓
  - "Todo backup completo = DB + filestore juntos" → el restore de prod restaura ambos. ✓
  - "Deploys a prod siempre manuales con aprobación" → el restore de prod (operación destructiva sobre datos reales) exige `CONFIRM=yes` explícito. ✓
  - "Staging es efímera, restaura + anonimiza antes de Odoo" → **no** se expone un restore de staging "crudo" que saltee la anonimización (ver Risks); el refresh de staging sigue siendo `staging-up` (ciclo completo). ✓
  - Layout 007 → todos los targets usan `Docker/...`, `env/.env.*`, nombres de proyecto `odoo-infrastructure-<stack>`. ✓
- Sin conflictos detectados.

## Architecture

```text
make <target>  (siempre desde la raíz del repo)
   │
   ├─ generado por template ($(eval $(call svc_targets,<stack>,<svc>))):
   │     <stack>-<svc>-up|stop|restart|logs   → $(COMPOSE_<stack>) <acción> <svc>
   │     <stack>-odoo-rebuild                  → build --no-cache + up -d (solo prod/staging)
   │     <stack>-<svc>-pull                    → pull (solo imágenes oficiales)
   │
   ├─ compuestos de stack (explícitos):
   │     <stack>-up | <stack>-down | <stack>-status | <stack>-logs
   │
   └─ especiales (explícitos, llaman scripts existentes):
         staging-up | staging-down | staging-extend   → ./scripts/staging-*.sh
         staging-db-restore                            → ./scripts/staging-up.sh  (refresh = ciclo completo, ver Risks)
         backup-backup-run  (+ alias backup)           → $(COMPOSE_backup) run --rm backup
         setup-backup-role | setup-monitoring-role     → ./scripts/setup-*-role.sh
         prod-db-restore CONFIRM=yes [LOCAL=yes]       → ./scripts/prod-db-restore.sh   ◀── única capacidad nueva
         help  (.DEFAULT_GOAL)                          → lista compuestos/especiales + la matriz de generación
```

**Restore de prod (US2) — el corazón de seguridad de la feature:**

```text
make prod-db-restore CONFIRM=yes [LOCAL=yes]
   └─ scripts/prod-db-restore.sh   (orquestador de host, bajo set -e)
        1. guard: [ "$CONFIRM" = yes ] o aborta sin tocar nada
        2. fuente: LOCAL=yes → repo restic local ; si no → R2 (default)
        3. build imagen de herramientas (Docker/Dockerfile.backup → odoo-restore-tools:local)
        4. $(COMPOSE_prod) stop odoo pgbouncer     ◀── libera conexiones a la DB odoo
        5. docker run --rm --network odoo-shared \
             --env-file env/.env.backup --env-file env/.env.prod \
             -v odoo-data:/filestore -v /srv/odoo-backups:/backups:ro \
             --entrypoint sh odoo-restore-tools:local /restore-prod.sh
        6. éxito → $(COMPOSE_prod) up -d   ;  fallo → set -e corta, Odoo queda parado (no sirve datos inconsistentes)

   scripts/restore-prod.sh   (dentro del contenedor de herramientas)
        - RESTIC_REPOSITORY = R2 o LOCAL según la env que le pasa el orquestador
        - restic restore latest --no-lock → WORKDIR   (--no-lock: repo montado :ro)
        - psql a la DB de mantenimiento `postgres` (db:5432, superusuario odoo):
            pg_terminate_backend de conexiones a `odoo` → DROP DATABASE odoo → CREATE DATABASE odoo
            (pg_dump -Fp es SQL plano; cargarlo sobre objetos existentes falla → DB fresca)
        - psql -d odoo -f db.sql   (carga el dump en la base recreada)
        - copiar filestore odoo/ → odoo-data:.local/share/Odoo/filestore/odoo   (sin rename, mismo db_name)
        - chown -R 100:101 /filestore   (Odoo corre como 100:101, no root — mismo fix que 005)
```

- **Reuso, no reimplementación**: `restore-prod.sh` es el gemelo de `restore-staging.sh` sin la anonimización, con `db_name=odoo` (no `odoo_staging`, sin rename de filestore) y con el paso extra DROP/CREATE (prod tiene una DB con datos; staging arranca con una DB vacía del init del contenedor). La imagen de herramientas (`Dockerfile.backup`) y el patrón `docker run --entrypoint` son los mismos que ya usa `staging-up.sh`.
- **Enumeración completa (US1, clarification B)**: el template cubre toda combinación válida de la tabla de `infrastructure-design.md`. `help` no vomita las ~60 líneas: lista los compuestos/especiales anotados + imprime la matriz (stacks · servicios · acciones) para que el patrón sea descubrible sin ruido.
- **CI-ready (US3)**: toda la lógica operativa queda tras un target; un pipeline futuro llama `make <target>` en vez de duplicar comandos.

## File Structure

```text
odoo-infrastructure/
├── Makefile                        ← nuevo (raíz). Vars COMPOSE_<stack>; template de targets generados; compuestos de stack; especiales que llaman scripts; help como .DEFAULT_GOAL; .PHONY para todos
├── scripts/
│   ├── prod-db-restore.sh          ← nuevo. Orquestador de host: guard CONFIRM=yes, elige R2/LOCAL, para odoo+pgbouncer, corre restore-prod.sh en el contenedor, reinicia; bajo set -e
│   └── restore-prod.sh             ← nuevo. Corre en Docker/Dockerfile.backup vía --entrypoint: restic restore (R2 o local) → DROP/CREATE odoo → psql load → filestore odoo/→odoo/ → chown 100:101
├── CLAUDE.md                       ← modificado. La sección "Common Commands" ya lista targets `make` como si existieran — confirmar que coinciden con los reales (`prod-up`, `prod-odoo-rebuild`, `prod-odoo-logs`, `staging-up`, `staging-down`, `edge-traefik-restart`, `monitoring-grafana-up`, `backup-backup-run`, `prod-db-restore CONFIRM=yes`) y ajustar donde diverja
├── INSTALL.md                      ← modificado. Nota de que el Makefile es la interfaz operativa (los comandos `docker compose` directos siguen válidos como equivalente); runbook del restore de prod (DR): `make prod-db-restore CONFIRM=yes` (R2) / `... LOCAL=yes` (local)
└── docs/infrastructure-design.md   ← modificado. La sección Makefile (líneas ~195-212) referencia un `./scripts/restore.sh prod/staging` que no existe — reconciliar al real (`prod-db-restore.sh`; staging refresh = `staging-up`)
```

`Docker/docker-compose.*.yml`, `env/.env.*`, `config/`, `scripts/staging-*.sh`, `scripts/setup-*-role.sh`, `scripts/restore-staging.sh`, `scripts/backup.sh`, `Docker/Dockerfile.backup` — sin cambios de contenido; el Makefile y el restore de prod los referencian tal cual.

## Data Model

N/A — el Makefile no tiene modelo. El restore de prod opera sobre el esquema Odoo ya existente (DROP/CREATE de la base `odoo` + carga del dump); no define modelo propio.

## API / Interface Contracts

- **Convención de target**: `<stack>-<servicio>-<acción>` (generados) + compuestos `<stack>-<up|down|status|logs>` + especiales nombrados. `<stack>` ∈ {prod, staging, edge, monitoring, backup}.
- **`make` / `make help`**: lista de comandos disponibles (default goal).
- **`make prod-db-restore CONFIRM=yes [LOCAL=yes]`**: restore destructivo de prod. Sin `CONFIRM=yes` exacto → aborta 0 cambios. `LOCAL=yes` → repo local; ausente → R2.
- **Precondición común**: correr desde la raíz del repo; `env/.env.<stack>` presentes (el Makefile no los crea — eso es INSTALL.md). El restore de prod además requiere `env/.env.backup` (config restic/R2) + `env/.env.prod` (superusuario Postgres).

## Dependencies

Ninguna nueva. GNU Make (presente por defecto). Reusa imágenes/scripts/compose existentes.

## Risks & Unknowns

- **Restore de prod destructivo sobre datos reales** — el DROP/CREATE de la base `odoo` es irreversible; si el snapshot elegido está corrupto o vacío, se perdió la DB previa. Mitigación: es disaster-recovery explícito (guard `CONFIRM=yes`), Odoo se para antes y solo reinicia si el restore salió `exit 0` (set -e); un fallo deja Odoo parado, no sirviendo datos a medias. Verificar en `implement` con smoke real (DB throwaway prod-like + repo restic real local **y** un "R2" de filesystem, como permite `.env.backup.example` y como se validó en 004/005): confirmar restore desde ambas fuentes, el guard rechazando sin `CONFIRM=yes`, y el rollback (fallo → exit≠0, Odoo parado).
- **`staging-db-restore` es un footgun si se implementa "crudo"** — restaurar datos de prod en staging sin anonimizar viola el invariante de 005 (Odoo nunca arranca sobre datos sin anonimizar). Decisión: `staging-db-restore` mapea a `staging-up` (ciclo completo restore+anonimización+up), no a un restore parcial. Se documenta; desvía a propósito del ejemplo viejo de la tabla de diseño (`./scripts/restore.sh staging`).
- **Recetas de Make = un shell por línea** — lógica multi-paso (guards, stop→run→start) va en los scripts, no en la receta (ponytail + honra "lógica en scripts"); las recetas del Makefile son de una línea que invocan el script o el compose. Evita bugs de estado entre líneas.
- **Targets generados por `eval` difíciles de debuggear** — mantener el template chico y los especiales explícitos; `make help` + `make -n <target>` (dry-run) permiten inspeccionar qué corre cada uno sin ejecutarlo.
- **Divergencia con CLAUDE.md** — los nombres ya publicitados deben coincidir literal; parte de `implement` es un grep de los targets prometidos contra los definidos.
- **`.env.*` ausentes** — los targets de compose fallan con el error nativo de Compose si falta el `.env.<stack>`; no se agrega manejo especial (mismo comportamiento que hoy con los comandos directos).

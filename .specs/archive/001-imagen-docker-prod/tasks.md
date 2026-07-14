---
name: imagen-docker-prod
code: TASKS-001
version: R01
date: 2026-07-10
---

# Tasks: Imagen Docker + Stack de Producción

## Phase 1: Setup

- [x] T001 [setup] Crear directorios `addons/enterprise/` y `addons/oca/`, cada uno con un archivo `.gitkeep` (vacíos a propósito), y crear el directorio `config/`
- [x] T002 [setup] **Revisado en implementación** — los addons custom están organizados en un repo por categoría (no uno solo). Creadas 13 carpetas placeholder con `.gitkeep` bajo `addons/custom/`: `sales`, `website`, `helpdesk`, `appraisals`, `services`, `accounting`, `sign`, `supply-chain`, `productivity`, `marketing`, `human-resources`, `technical`, `administration`. Cada una se reemplaza por `git submodule add <url> addons/custom/<categoria>` a medida que exista la URL (ninguna disponible todavía, ni siquiera `sales`). Pendiente para `/converge`: reflejar este cambio de estructura en `spec.md`/`plan.md` de forma permanente.
- [x] T003 [setup] Actualizar `.gitignore`: agregar entradas `docker-compose.override.yml`, `.env.prod`, `.env.staging`

## Phase 2: Imagen reproducible por commit (US1)

- [x] T004 [US1] Escribir `Dockerfile` en la raíz. **2 bugs reales corregidos en verificación:**
  1. `find -exec pip3 install ... \;` no propaga el exit code de `pip3` (`find` devuelve 0 aunque el comando `-exec`'d falle) — el build "pasaba" incluso con un paquete inexistente en `requirements.txt`, violando el edge case del spec. Cambiado a `find ... -print0 | xargs -0 -r -n1 pip3 install ...`, que sí propaga el fallo.
  2. La imagen base (`odoo:19.0-20260630`, Python 3.12/Debian) aplica PEP 668 (`externally-managed-environment`) — `pip3 install` fallaba incluso con un paquete válido (`cowsay`), sin relación con el bug #1. Se agregó `--break-system-packages` (estándar dentro de un contenedor Docker ya aislado).
  Confirmado con 3 casos: paquete válido instala y es importable, paquete inexistente falla el build (exit 123), sin `requirements.txt` el build pasa.
  **Reescrito en Phase 6 (T019)**: `Dockerfile` pasó a multi-stage — stage `build` corre `git-aggregator` para agregar los addons custom pineados, stage final copia el resultado vía `COPY --from=build` (ya no `COPY addons/custom` directo). Descripción vigente en `plan.md` File Structure.
- [x] T005 [US1][US4] Escribir `config/odoo.conf`: `addons_path` en orden `enterprise → custom (13 categorías: sales, website, helpdesk, appraisals, services, accounting, sign, supply-chain, productivity, marketing, human-resources, technical, administration) → oca → core`, `list_db = False`, `proxy_mode = True`, `workers = 3`, `max_cron_threads = 2`, `limit_memory_soft = 1717567488` (1638 MiB en bytes), `limit_memory_hard = 2147483648` (2048 MiB en bytes). **Ajustado en verificación**: se agregó `db_name = odoo` — sin él, el contenedor (que corre sin `-d` explícito) no sabe contra qué base operar y `/web/health` nunca responde 200, incluso con la DB inicializada. No estaba en el plan/tasks original; pendiente para `/converge`. También se confirmó que Odoo sí loguea un `WARNING` por cada entrada de `addons_path` vacía (contradice la conclusión de `/analyze` en F3 — sí hay log, aunque no bloquea el arranque; corregir en `/converge`).
- [x] T006 [US1] Escribir instrucciones de build manual en `INSTALL.md`: `docker build -t odoo-prod:$(git rev-parse --short HEAD) .` y cómo verificar el tag de commit sobre la imagen resultante

## Phase 3: Stack de producción sano y con sizing aplicado (US2, US4)

- [x] T007 [US2][US4] En `docker-compose.prod.yml`, definir el servicio `db` (`postgres:16-alpine`): env `POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB`/`PGDATA=/var/lib/postgresql/data/pgdata`/`POSTGRES_INITDB_ARGS="--locale-provider=icu --icu-locale=en-US"`, `shared_buffers=1.5GB`/`work_mem=64MB`/`max_connections=100`/`random_page_cost=1.1` (vía `command:` o config montada), volumen con nombre `db-data`, healthcheck `pg_isready -U ${POSTGRES_USER}` (interval 10s, timeout 5s, retries 5, start_period 30s), `restart: unless-stopped`, `mem_limit`/`cpus`, sin `ports:`
- [x] T008 [US2][US4] En `docker-compose.prod.yml`, definir el servicio `pgbouncer` (`edoburu/pgbouncer`), depende de `db` (`condition: service_healthy`): env `DB_HOST=db`/`DB_PORT=5432`/`DB_USER`/`DB_PASSWORD`/`POOL_MODE=transaction`/`DEFAULT_POOL_SIZE=20`/`MAX_CLIENT_CONN=200`/`LISTEN_PORT=6432`/`AUTH_TYPE=scram-sha-256`, `restart: unless-stopped`, `mem_limit`/`cpus`, sin `ports:`. **Ajustado en verificación**: se agregó healthcheck (`pg_isready -h 127.0.0.1 -p 6432`, confirmado funcional contra el puerto de PgBouncer) — sin él, `odoo`'s `depends_on: condition: service_healthy` fallaba al arrancar, ya que Compose exige que el servicio dependido tenga un healthcheck propio. No estaba en el plan/tasks original; pendiente para `/converge`.
- [x] T009 [US2][US4] En `docker-compose.prod.yml`, definir el servicio `odoo` (imagen construida en T004), depende de `pgbouncer` (`condition: service_healthy`): env `HOST=pgbouncer`/`PORT=6432`/`USER`/`PASSWORD`, monta `config/odoo.conf:/etc/odoo/odoo.conf:ro` y volumen con nombre `odoo-data:/var/lib/odoo`, healthcheck `curl -f http://localhost:8069/web/health` (interval 30s, timeout 10s, retries 3, start_period 60s), `restart: unless-stopped`, log rotation `json-file` (`max-size: 50m`, `max-file: 5`), `mem_limit`/`cpus`, sin `ports:`; declarar la red interna y los volúmenes con nombre (`db-data`, `odoo-data`) a nivel de archivo
- [x] T010 [P][US2] Crear `.env.prod.example` con las variables de T007/T008/T009 como plantilla (valores placeholder, nunca reales) — el `.env.prod` real no se versiona (ver T003)

## Phase 4: Exposición temporal para probar sin `edge` (US3)

- [x] T011 [US3] Crear `docker-compose.override.yml.example`: bloque comentado que mapea `127.0.0.1:8069:8069` en el servicio `odoo` — instrucción de copiarlo a `docker-compose.override.yml` (gitignored) para habilitarlo localmente

## Verification

- [x] VERIFY US1 — Confirmado. Usuario `odoo` (no root); `docker build -t odoo-prod:$(git rev-parse --short HEAD) .` funciona como documentado en `INSTALL.md`; paquete válido en `requirements.txt` se instala y es importable (requirió agregar `--break-system-packages`, ver T004)
- [x] VERIFY US2 — Confirmado. Los 3 servicios llegan a `healthy`; `odoo` esperó a `db`/`pgbouncer` healthy antes de arrancar (observado en la secuencia real de `up -d`); `/web/health` respondió 200 desde otro contenedor en la red interna (`curlimages/curl`); `docker inspect` confirmó `PortBindings: map[]` en los 3 (sin override); `odoo.conf` dentro del contenedor muestra `list_db=False`/`proxy_mode=True` (y el `db_name=odoo` agregado, ver T005)
- [x] VERIFY US3 — Confirmado. Con `docker-compose.override.yml` copiado del `.example`, `docker port` mostró `8069/tcp -> 127.0.0.1:8069` y `curl` respondió 200; sin el archivo, `PortBindings` vacío
- [x] VERIFY US4 — Confirmado. `docker inspect` mostró `Memory`/`NanoCpus` seteados en los 3 contenedores; `odoo.conf` con los valores exactos de workers/memoria; Postgres respondió `shared_buffers=1536MB`, `work_mem=64MB`, `max_connections=100`, `random_page_cost=1.1` vía `SHOW`; PgBouncer confirmado leyendo `/etc/pgbouncer/pgbouncer.ini` directamente (el admin console vía `psql` rechazó la conexión — comportamiento esperado, no todo usuario es admin de PgBouncer)
- [x] VERIFY Edge case — Confirmado indirectamente: la secuencia real de arranque (`db` en estado `Waiting`→`Healthy`, recién ahí `pgbouncer` arranca, y luego `odoo`) demuestra que `depends_on: condition: service_healthy` bloquea correctamente sin importar cuánto tarde `db`; no crashea ni hace loop
- [x] VERIFY Edge case — Confirmado tras corregir 2 bugs reales en T004 (propagación de exit code + PEP 668): build con paquete inexistente falla con exit 123, visible y claro
- [x] VERIFY Edge case — Confirmado: `echo test >> /etc/odoo/odoo.conf` dentro del contenedor devolvió `Read-only file system`, el contenedor siguió corriendo sin problema
- [x] VERIFY No se crearon archivos fuera de los listados en la sección "File Structure" de `plan.md` — confirmado con `git status --short`, coincide exactamente
- [x] VERIFY No se agregaron dependencias fuera de las listadas en la sección "Dependencies" de `plan.md` — confirmado, solo `odoo:19.0-20260630`, `postgres:16-alpine`, `edoburu/pgbouncer`

## Phase 5: Convergence

- [x] T012 Corregir `plan.md` "Risks & Unknowns": Odoo sí loguea un `WARNING` por cada entrada de `addons_path` vacía — contradice la resolución previa de F3 en `/analyze` ("no era un riesgo real... sigue sin loguear nada"). Sin impacto funcional, solo corrección de documentación (contradicts)
- [x] T013 Actualizar `plan.md` File Structure: agregar `db_name` a la descripción de `config/odoo.conf` (partial)
- [x] T014 Actualizar `plan.md` File Structure: agregar `--break-system-packages` y el uso de `find | xargs` (en vez de `find -exec`) a la descripción del `Dockerfile` (partial)
- [x] T015 Ajustar `spec.md` US1 (narrativa y AC1): de "el submódulo de addons custom" (singular) a redacción plural, reflejando la estructura real de 13 submódulos por categoría (contradicts)
- [~] T016 **Superado por Phase 6** — se descartaron los git submodules por decisión del usuario (fricción operativa); reemplazado por `git-aggregator` (ver T017-T020)

## Phase 6: git-aggregator reemplaza submodules

- [x] T017 Eliminar los 13 placeholders `addons/custom/<categoria>/.gitkeep` (`sales`, `website`, `helpdesk`, `appraisals`, `services`, `accounting`, `sign`, `supply-chain`, `productivity`, `marketing`, `human-resources`, `technical`, `administration`)
- [x] T018 Crear `addons/custom/repos.yaml` — config de `git-aggregator`, sin entradas reales todavía (ninguna URL disponible, ni `sales`); comentarios mostrando el formato esperado para cuando existan
- [x] T019 Reescribir `Dockerfile` a multi-stage: stage `build` instala `git-aggregator` (pip, `--break-system-packages`) y corre `gitaggregate -c addons/custom/repos.yaml`; stage final `FROM odoo:19.0-20260630` copia el resultado vía `COPY --from=build`, sin git/pip/git-aggregator en la imagen final
- [x] T020 VERIFY — Confirmado. Build multi-stage exitoso con `repos.yaml` sin entradas (`gitaggregate` no-op en 0.1s); `/mnt/custom-addons` existe vacío; `git`/`gitaggregate` no presentes en la imagen final (`which` retorna exit 1 para ambos); stack completo (`db`+`pgbouncer`+`odoo`) levantado, inicializado y `/web/health` respondió 200, igual que con la versión anterior basada en submodules

## Phase 7: Convergence

- [x] T021 Corregir `tasks.md` T004: quedó un resto de texto pegado de la edición anterior describiendo el `Dockerfile` viejo (`COPY addons/custom /mnt/custom-addons`, un solo stage) — contradice el `Dockerfile` real actual (multi-stage con `git-aggregator`, `COPY --from=build`) (contradicts)

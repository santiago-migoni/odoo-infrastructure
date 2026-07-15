---
name: stack-layout-reorg
code: TASKS-013
version: R00
date: 2026-07-15
---

# Tasks: Reorganización de layout por stack + imágenes Docker independientes

## Phase 1: Setup — mover config/env (US1)

- [x] T001 [P][US1] `mkdir -p prod/docker prod/config prod/env`; `git mv config/odoo.conf.example prod/config/odoo.conf.example`; `git mv env/.env.prod.example prod/env/.env.prod.example`
- [x] T002 [P][US1] `mkdir -p staging/docker staging/config staging/env`; `git mv config/odoo-staging.conf.example staging/config/odoo-staging.conf.example`; `git mv env/.env.staging.example staging/env/.env.staging.example`
- [x] T003 [P][US1] `mkdir -p backup/docker backup/env`; `git mv env/.env.backup.example backup/env/.env.backup.example` (sin `backup/config/` — no hay archivo que mover)
- [x] T004 [P][US1] `mkdir -p edge/docker edge/config edge/env`; `git mv config/traefik.yml edge/config/traefik.yml`; `git mv config/traefik-dynamic.yml edge/config/traefik-dynamic.yml`; `git mv env/.env.edge.example edge/env/.env.edge.example`
- [x] T005 [P][US1] `mkdir -p monitoring/docker monitoring/config monitoring/env`; `git mv config/prometheus.yml monitoring/config/prometheus.yml`; `git mv config/loki-config.yml monitoring/config/loki-config.yml`; `git mv config/promtail-config.yml monitoring/config/promtail-config.yml`; `git mv config/grafana monitoring/config/grafana`; `git mv env/.env.monitoring.example monitoring/env/.env.monitoring.example`

## Phase 2: Compose files + imagen de Odoo independiente (US1, US2)

- [x] T006 Depends on T001 — `git mv docker/docker-compose.prod.yml prod/docker/docker-compose.yml`; corregir `build.context` de `..` a `../..` y `dockerfile:` de `docker/Dockerfile` a `prod/docker/Dockerfile`; confirmar que `env_file:`/mounts de config quedan como `../env/...`/`../config/...` (misma profundidad relativa, sin cambio de valor)
- [x] T007 Depends on T002 — `git mv docker/docker-compose.staging.yml staging/docker/docker-compose.yml`; mismo fix de `build.context`/`dockerfile:` que T006, apuntando a `staging/docker/Dockerfile`
- [x] T008 [P][US1] `git mv docker/docker-compose.edge.yml edge/docker/docker-compose.yml` (sin build propio, sin fix de context)
- [x] T009 [P][US1] `git mv docker/docker-compose.monitoring.yml monitoring/docker/docker-compose.yml` (sin build propio, sin fix de context)
- [x] T010 [US2] Depends on T006 — `git mv docker/Dockerfile prod/docker/Dockerfile` (queda como el original, contenido sin cambios)
- [x] T011 [US2] Depends on T007, T010 — `cp prod/docker/Dockerfile staging/docker/Dockerfile` (copia independiente, idéntica al día uno — no symlink, no include)

## Phase 3: Imagen de herramientas independiente por stack (US3)

- [x] T012 [US3] `mkdir -p backup/docker`; `git mv docker/Dockerfile.backup backup/docker/Dockerfile` (queda como el original de la imagen de backup, renombrado)
- [x] T013 [US3] Depends on T012 — `cp backup/docker/Dockerfile staging/docker/Dockerfile.tools` (copia independiente, idéntica al día uno)
- [x] T014 [US3] Depends on T012 — `cp backup/docker/Dockerfile prod/docker/Dockerfile.tools` (copia independiente, idéntica al día uno)
- [x] T015 [US3] Depends on T003 — `git mv docker/docker-compose.backup.yml backup/docker/docker-compose.yml`; corregir `build.context` de `..` a `../..` y `dockerfile:` de `docker/Dockerfile.backup` a `backup/docker/Dockerfile`

## Phase 4: Actualizar todo lo que referencia los paths viejos (US4)

- [x] T016 [US4] Depends on T006-T015 — `scripts/mk-dispatch.sh`: `compose_file_for()` pasa de `"docker/docker-compose.$1.yml"` a `"$1/docker/docker-compose.yml"`; la línea literal de `run-backup` pasa a `docker compose -f backup/docker/docker-compose.yml exec -T backup /usr/local/bin/backup.sh`
- [x] T017 [US4] Depends on T007, T013 — `scripts/refresh-staging.sh`: `env/.env.staging` → `staging/env/.env.staging`; `docker-compose.staging.yml` → `staging/docker/docker-compose.yml` (las 3 apariciones); `docker/Dockerfile.backup` → `staging/docker/Dockerfile.tools`
- [x] T018 [P][US4] Depends on T007 — `scripts/nuke-staging.sh`: `docker/docker-compose.staging.yml` → `staging/docker/docker-compose.yml`
- [x] T019 [US4] Depends on T006, T014 — `scripts/prod-db-restore.sh`: `env/.env.backup` → `backup/env/.env.backup`; `env/.env.prod` → `prod/env/.env.prod`; `docker-compose.prod.yml` → `prod/docker/docker-compose.yml` (las 2 apariciones); `docker/Dockerfile.backup` → `prod/docker/Dockerfile.tools`
- [x] T020 [P][US4] Depends on T006 — `scripts/setup-backup-role.sh`: `env/.env.prod` → `prod/env/.env.prod`; `docker-compose.prod.yml` → `prod/docker/docker-compose.yml`
- [x] T021 [P][US4] Depends on T006 — `scripts/setup-monitoring-role.sh`: `env/.env.prod` → `prod/env/.env.prod`; `docker-compose.prod.yml` → `prod/docker/docker-compose.yml`
- [x] T022 [US4] Depends on T015 — `systemd/odoo-backup.service`: `ExecStart=` pasa a `docker compose -f backup/docker/docker-compose.yml exec -T backup /usr/local/bin/backup.sh`
- [x] T023 [P][US4] Depends on T001-T005 — `.gitignore`: las 5 rutas de `env/.env.<stack>` pasan a `<stack>/env/.env.<stack>`, `config/odoo.conf`/`config/odoo-staging.conf` pasan a `prod/config/odoo.conf`/`staging/config/odoo-staging.conf`; resolver la entrada muerta `docker/docker-compose.override.yml` (confirmar que no se usa en ningún lado y eliminarla, o actualizarla si aparece algún uso real)

## Phase 5: Documentación

- [x] T024 Depends on T016-T023 — `INSTALL.md`: actualizar todas las rutas de comandos (`docker compose -f ...`, `cp .../....example ...`, referencias a scripts) a los paths nuevos, paso por paso
- [x] T025 [P] Depends on T016-T023 — `CLAUDE.md`: tabla de arquitectura de los 5 stacks y cualquier ejemplo de path
- [x] T026 [P] Depends on T016-T023 — `README.md`: tabla de arquitectura si menciona rutas de archivo

## Phase 6: Limpieza

- [x] T027 Depends on T001-T015 — confirmar que `config/`, `docker/`, `env/` de primer nivel quedaron vacíos y eliminarlos (`rmdir` o `rm -rf` solo si están genuinamente vacíos — no forzar si quedó algo sin mover)

## Verification

- [x] VERIFY [US1] Listar la raíz del repo — no quedan `config/`, `docker/`, `env/` de primer nivel; `scripts/`, `systemd/`, `addons/` siguen ahí sin cambios (spec US1 escenario 2 y 3)
- [x] VERIFY [US1] Listar `prod/` — aparecen `docker/docker-compose.yml`, `docker/Dockerfile`, `docker/Dockerfile.tools`, `config/odoo.conf.example`, `env/.env.prod.example` (spec US1 escenario 1)
- [x] VERIFY [US2] `diff prod/docker/Dockerfile staging/docker/Dockerfile` — sin diferencias (mismo punto de partida, spec US2 escenario 1)
- [x] VERIFY [US2] Build real de `prod/docker/docker-compose.yml` (`docker compose -f prod/docker/docker-compose.yml build odoo`) — confirma que `context: ../..` resuelve a la raíz y `addons/` se copia bien
- [x] VERIFY [US2] Build real de `staging/docker/docker-compose.yml` (`docker compose -f staging/docker/docker-compose.yml build odoo-staging`) — mismo chequeo
- [x] VERIFY [US2] Editar solo `staging/docker/Dockerfile`, correr `make rebuild-prod-odoo` — la imagen de prod no cambia (spec US2 escenario 2)
- [x] VERIFY [US3] `diff backup/docker/Dockerfile staging/docker/Dockerfile.tools` y `diff backup/docker/Dockerfile prod/docker/Dockerfile.tools` — sin diferencias (spec US3 escenario 1)
- [x] VERIFY [US3] Build real de `backup/docker/docker-compose.yml` (`docker compose -f backup/docker/docker-compose.yml build backup`) — confirma `context: ../..`
- [x] VERIFY [US4] `make help`, `make ps`, `make up-<stack>`/`make down-<stack>` para los 5 stacks — funcionan igual que antes (spec US4 escenario 1)
- [x] VERIFY [US4] `make run-backup`, `make refresh-staging`, `make restore-prod` (sin `CONFIRM=yes`, debe abortar igual que siempre), `make nuke-staging` — resuelven a los paths nuevos correctamente (spec US4 escenario 2)
- [x] VERIFY [US4] `systemd/odoo-backup.service`/`systemd/staging-refresh.service` — `ExecStart=` apunta a rutas válidas post-reorg (spec US4 escenario 3)
- [x] VERIFY No se modificó la lógica interna de `backup.sh`/el contenido funcional de los scripts más allá de los paths (spec Non-Goals)
- [x] VERIFY No quedan referencias a `docker/docker-compose.<stack>.yml`, `docker/Dockerfile`, `docker/Dockerfile.backup`, `config/<archivo>`, `env/.env.<stack>` (rutas viejas) en ningún archivo activo del repo (`INSTALL.md`, `CLAUDE.md`, `README.md`, `scripts/*.sh`, `systemd/*.service`, `.gitignore`, `Makefile`) — excluyendo `.specs/archive/` y `CHANGELOG.md`, que son historial y no se tocan

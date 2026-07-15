---
name: makefile-ux
code: TASKS-012
version: R00
date: 2026-07-14
---

# Tasks: Makefile UX — Comandos Descubribles

## Phase 1: Setup — renombrar scripts de tarea

- [x] T001 [P] `git mv scripts/staging-up.sh scripts/refresh-staging.sh`; actualizar el prefijo de log interno de `[staging-up]` a `[refresh-staging]`
- [x] T002 [P] `git mv scripts/staging-down.sh scripts/nuke-staging.sh`; actualizar el prefijo de log interno de `[staging-down]` a `[nuke-staging]` (agregar el prefijo si no lo tenía)
- [x] T003 [P] ~~`git mv scripts/prod-db-restore.sh scripts/restore-prod.sh`~~ — **revertido**: `scripts/restore-prod.sh` ya existe como el worker interno (equivalente a `restore-staging.sh`, montado por path dentro del `docker run` del orquestador), no es un nombre libre. `scripts/prod-db-restore.sh` se queda con su nombre y su prefijo `[prod-db-restore]` sin cambios — igual que `backup.sh`. El comando nuevo `restore-prod` delega a `scripts/prod-db-restore.sh` sin renombrarlo (ver T011)
- [x] T004 Depends on T001 — actualizar `ExecStart=` en `systemd/staging-refresh.service` para apuntar a `scripts/refresh-staging.sh`

## Phase 2: Dispatcher — motor de parseo y ejecución (US1, US2, US3)

- [x] T005 Crear `scripts/mk-dispatch.sh` con las tablas estáticas: lista de 5 stacks, ruta de compose file por stack, lista de servicios por stack, y lista de servicios de build propio (`prod/odoo`, `staging/odoo-staging`, `backup/backup`) para validar `pull`/`rebuild`
- [x] T006 Depends on T005 — implementar extracción del verbo: primer segmento antes del primer `-` del target recibido, contra la tabla fija (`up stop down ps logs restart pull rebuild`)
- [x] T007 Depends on T006 — implementar resolución de stack/servicio del resto del target: matchear contra los 5 stacks conocidos (igualdad exacta, o prefijo seguido de `-`), el remanente (si lo hay) es el servicio, validado contra la lista real de ese stack
- [x] T008 [US1] Depends on T007 — implementar el menú de verbo desnudo: sin stack/servicio en el target, imprimir cada combinación válida de ese verbo (respetando el filtro de build-propio en `pull`/`rebuild`) y salir con código 0 sin ejecutar nada
- [x] T009 [US2] Depends on T007 — implementar los errores guiados: `down` con servicio → sugiere `stop-<stack>-<servicio>`; `pull` sobre servicio de build propio → sugiere `rebuild-<stack>-<servicio>`; `rebuild` sobre servicio de imagen oficial → sugiere `pull-<stack>-<servicio>`; stack/servicio inexistente → lista las opciones reales de ese verbo
- [x] T010 [US1][US3] Depends on T008, T009 — implementar la ejecución real contra `docker compose`, siguiendo la tabla verbo→comando de `plan.md` (`up -d`, `stop`, `down` sin `-v` nunca, `ps`, `logs -f`, `restart`, `pull`, `build --no-cache && up -d`)

## Phase 3: Tareas con nombre propio (US4)

- [x] T011 Depends on T005 — agregar al dispatcher el match literal de TAREAS: `run-backup`, `refresh-staging`, `restore-prod` (lee `$CONFIRM`/`$LOCAL` del entorno), `nuke-staging`, `setup-backup-role`, `setup-monitoring-role` — cada uno delega al script/comando equivalente de hoy
- [x] T012 Depends on T011 — agregar el match literal de los alias retirados: `restore-staging` imprime la explicación del invariante (staging nunca se restaura parcial) y apunta a `refresh-staging`; `backup` imprime la distinción entre `up-backup` y `run-backup` — ninguno ejecuta nada
- [x] T013 Depends on T011, T012 — implementar la salida de `make help`: sección STACKS (grilla concreta verbo-stack con el listado de servicios de referencia) + sección TAREAS (comandos completos con `make`) + línea de descubribilidad de verbos

## Phase 4: Estado global (US5)

- [x] T014 Depends on T005 — implementar `ps` desnudo (bare, sin stack): correr `docker compose -f docker/docker-compose.<stack>.yml ps --format json` por cada uno de los 5 stacks, parsear, y renderizar tabla `STACK | SERVICIO | ESTADO`; stacks sin contenedores muestran `— stack abajo —`

## Phase 5: Integración con Make

- [x] T015 Depends on T006-T014 — reescribir `Makefile`: eliminar todas las macros/variables de generación de targets; dejar `.DEFAULT_GOAL := help`, un target `help:` y una regla catch-all `%:`, ambos delegando a `scripts/mk-dispatch.sh $@`
- [x] T016 [P] Depends on T015 — `chmod +x scripts/mk-dispatch.sh`

## Phase 6: Documentación

- [x] T017 [P] Actualizar ejemplos de comandos en `CLAUDE.md` (sección "Common Commands") a la convención `<verbo>-<stack>[-<servicio>]`
- [x] T018 [P] Actualizar ejemplos de comandos en `README.md` (sección "Operación diaria") a la convención nueva
- [x] T019 [P] Actualizar ejemplos de comandos en `INSTALL.md` (todas las menciones de `make prod-...`, `make prod-db-restore`, `make monitoring-...`, etc.) a la convención nueva
- [x] T020 [P] Agregar item a `.specs/backlog.md`: `scripts/next-feature-number.sh` no escanea `.specs/archive/`, devuelve `001` en vez del siguiente número real (hallazgo de esta sesión, fuera de alcance de este spec)

## Verification

- [x] VERIFY [US1] `make down` (sin stack) imprime el menú de las 5 combinaciones válidas, sin ejecutar ningún `docker compose` (spec US1 escenario 1 y 3)
- [x] VERIFY [US1] `make pull` imprime solo las combinaciones de servicios con imagen oficial, sin incluir `prod-odoo`/`staging-odoo-staging`/`backup-backup` (spec US1 escenario 2)
- [x] VERIFY [US2] `make pull-prod-odoo` guía hacia `rebuild-prod-odoo` en vez de fallar con `No rule to make target` (spec US2 escenario 1)
- [x] VERIFY [US2] `make rebuild-prod-db` guía hacia `pull-prod-db` (spec US2 escenario 2)
- [x] VERIFY [US2] `make up-produ` (typo) lista los stacks reales en vez de un error genérico (spec US2 escenario 3)
- [x] VERIFY [US3] `make down-staging` conserva los volúmenes de staging (no pasa `-v`) — comportamiento distinto al `staging-down` viejo (spec US3 escenario 1)
- [x] VERIFY [US3] `make nuke-staging` es el único comando que borra volúmenes; `make nuke` (desnudo) lista solo `nuke-staging`, no existe `nuke-prod` (spec US3 escenario 2 y 3)
- [x] VERIFY [US4] `make run-backup` corre el job dentro del contenedor ya levantado; `make up-backup` es un comando distinto (spec US4 escenario 1)
- [x] VERIFY [US4] `make refresh-staging` corre el ciclo completo restore+anonimización+up (spec US4 escenario 2)
- [x] VERIFY [US4] `make restore-staging` explica el invariante y no ejecuta nada (spec US4 escenario 3)
- [x] VERIFY [US4] `make restore-prod` sin `CONFIRM=yes` aborta; con `CONFIRM=yes` [`LOCAL=yes`] corre (spec US4 escenario 4)
- [x] VERIFY [US4] `make help` muestra las dos secciones (STACKS y TAREAS) descritas en el spec (spec US4 escenario 5)
- [x] VERIFY [US5] `make ps` muestra una sola tabla `STACK | SERVICIO | ESTADO` para los 5 stacks, no 5 bloques nativos (spec US5 escenario 1 y 2)
- [x] VERIFY `rebuild-backup-backup` existe y funciona (hueco preexistente cerrado, spec Edge Cases)
- [x] VERIFY No quedan referencias a nombres de comando viejos (`prod-up`, `prod-db-restore`, `staging-up`, etc.) en `CLAUDE.md`/`README.md`/`INSTALL.md`
- [x] VERIFY No se modificó ningún `docker-compose.*.yml` ni la lógica interna de `backup.sh`/los 3 scripts renombrados más allá del rename (spec Non-Goals)

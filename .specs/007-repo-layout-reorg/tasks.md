---
name: repo-layout-reorg
code: TASKS-007
version: R00
date: 2026-07-13
---

# Tasks: Reorganización de layout — `Docker/` y `env/`

## Phase 1: Setup — relocar archivos (sin editar contenido todavía)

- [x] T001 [setup] `git mv` de los 5 compose + 2 Dockerfiles a `Docker/`: `docker-compose.prod.yml`, `docker-compose.staging.yml`, `docker-compose.edge.yml`, `docker-compose.monitoring.yml`, `docker-compose.backup.yml`, `Dockerfile`, `Dockerfile.backup` — solo relocación, contenido intacto
- [x] T002 [P][setup] `git mv` de las 5 plantillas a `env/`: `.env.prod.example`, `.env.staging.example`, `.env.edge.example`, `.env.monitoring.example`, `.env.backup.example` — solo relocación

## Phase 2: Build context, mounts y env_file en `Docker/` (US1)

- [x] T003 [US1] Editar `Docker/docker-compose.prod.yml`: `build: .` → `{context: .., dockerfile: Docker/Dockerfile}`; `env_file: .env.prod` (servicios `db`, `pgbouncer`, `odoo`) → `../env/.env.prod`; volume `./config/odoo.conf` → `../config/odoo.conf`
- [x] T004 [P][US1] Editar `Docker/docker-compose.staging.yml`: `build: .` (servicio `odoo-staging`) → `{context: .., dockerfile: Docker/Dockerfile}`; `env_file: .env.staging` (servicios `db`, `pgbouncer`, `odoo-staging`, `postgres-exporter`) → `../env/.env.staging`; volume `./config/odoo-staging.conf` → `../config/odoo-staging.conf`
- [x] T005 [P][US1] Editar `Docker/docker-compose.edge.yml`: `env_file: .env.edge` → `../env/.env.edge`; volumes `./config/traefik.yml` y `./config/traefik-dynamic.yml` → `../config/traefik.yml`, `../config/traefik-dynamic.yml`
- [x] T006 [P][US1] Editar `Docker/docker-compose.monitoring.yml`: `env_file: .env.monitoring` (servicios `grafana`, `postgres-exporter-prod`) → `../env/.env.monitoring`; volumes `./config/prometheus.yml`, `./config/grafana/provisioning`, `./config/loki-config.yml`, `./config/promtail-config.yml` → `../config/...`
- [x] T007 [P][US1] Editar `Docker/docker-compose.backup.yml`: `build: {context: ., dockerfile: Dockerfile.backup}` → `{context: .., dockerfile: Docker/Dockerfile.backup}`; `env_file: .env.backup` → `../env/.env.backup`

## Phase 3: `.gitignore` (US2)

- [x] T008 [US2] Editar `.gitignore`: `.env.prod`/`.env.staging`/`.env.edge`/`.env.backup`/`.env.monitoring` → `env/.env.prod`, `env/.env.staging`, `env/.env.edge`, `env/.env.backup`, `env/.env.monitoring`; `docker-compose.override.yml` → `Docker/docker-compose.override.yml`

## Phase 4: Scripts y systemd (US4)

- [x] T009 [US4] Editar `scripts/staging-up.sh`: `docker compose -f docker-compose.staging.yml` (2 ocurrencias) → `-f Docker/docker-compose.staging.yml`; `. ./.env.staging` → `. ./env/.env.staging`; `docker build -f Dockerfile.backup` → `-f Docker/Dockerfile.backup`; `docker run --env-file .env.staging` → `--env-file env/.env.staging`
- [x] T010 [P][US4] Editar `scripts/staging-down.sh`: `docker compose -f docker-compose.staging.yml` → `-f Docker/docker-compose.staging.yml`
- [x] T011 [P][US4] Editar `scripts/setup-backup-role.sh`: `docker compose -f docker-compose.prod.yml` → `-f Docker/docker-compose.prod.yml`; `. ./.env.prod` → `. ./env/.env.prod`
- [x] T012 [P][US4] Editar `scripts/setup-monitoring-role.sh`: mismo patrón que T011 (`-f Docker/docker-compose.prod.yml`, `. ./env/.env.prod`)
- [x] T013 [P][US4] Editar `systemd/odoo-backup.service`: `ExecStart=... -f docker-compose.backup.yml` → `-f Docker/docker-compose.backup.yml`
- [x] T014 [P][US4] Editar `systemd/staging-teardown-boot.service`: `ExecStart=... -f docker-compose.staging.yml` → `-f Docker/docker-compose.staging.yml`

## Phase 5: Documentación (US2, US3)

- [x] T015 [US2][US3] Editar `INSTALL.md`: todas las invocaciones `docker compose -f docker-compose.<stack>.yml` (~20 ocurrencias en los 8 pasos) → `-f Docker/docker-compose.<stack>.yml`; todos los `cp .env.<stack>.example .env.<stack>` → `cp env/.env.<stack>.example env/.env.<stack>`; el `docker build -t odoo-prod:... .` del paso 2 (sin `-f` hoy) → agregar `-f Docker/Dockerfile`
- [x] T016 [P][US3] Editar `CLAUDE.md`: tabla de stacks y ejemplos de comandos con paths `docker-compose.<stack>.yml` → `Docker/docker-compose.<stack>.yml`
- [x] T017 [P][US3] Editar `docs/infrastructure-design.md`: columna "archivo" de la tabla de stacks y las menciones de comando literal (`docker compose -f docker-compose.backup.yml run --rm backup`) → paths con prefijo `Docker/`

## Phase 6: Nombre de proyecto Compose (pedido explícito post-VERIFY US4)

- [x] T018 Agregar `name: odoo-infrastructure-<stack>` como primera clave de cada una de las 5 `Docker/docker-compose.<stack>.yml` — el reorg había cambiado el nombre de proyecto implícito de `odoo-infrastructure` (nombre de la carpeta raíz) a `docker` (nombre de la nueva carpeta contenedora), pedido explícito del usuario para restaurar el branding. **No se usó el mismo literal `odoo-infrastructure` en las 5** — un test real reveló que eso colisiona (`prod` y `staging` comparten servicios llamados `db`/`pgbouncer`; mismo project+service → mismo nombre de contenedor → Compose recrea y reemplaza el contenedor del otro stack). Sufijo por stack evita la colisión manteniendo el prefijo pedido.

## Verification

- [x] VERIFY US1 — **Confirmado con build real**: `docker build -f Docker/Dockerfile -t verify-odoo .` y `docker build -f Docker/Dockerfile.backup -t verify-backup .` (contexto `.` = raíz) completaron sin error — `COPY addons/oca`, `COPY addons/custom/repos.yaml`, `COPY addons/enterprise`, `COPY scripts/backup.sh` resolvieron correctamente desde la raíz (cache hit exacto contra el build pre-reorg, señal fuerte de que el context/dockerfile quedaron bien emparejados). `docker inspect --format '{{.Config.User}}' verify-odoo` → `odoo`, como antes. Imágenes de prueba eliminadas al terminar.
- [x] VERIFY US1 — **Confirmado real**: `docker compose -f Docker/docker-compose.<stack>.yml config -q` pasa para las 5 (`prod`, `staging`, `edge`, `monitoring`, `backup`) con `env/.env.<stack>` reales poblados (copiados de la plantilla) — `env_file` y los mounts `../config/...` resuelven sin error.
- [x] VERIFY US2 — **Confirmado real**: `docker compose -f Docker/docker-compose.prod.yml config` muestra `POSTGRES_USER: odoo` / `POSTGRES_PASSWORD: changeme` realmente resueltos desde `env/.env.prod` (no vacíos).
- [x] VERIFY US3 — grep final de rutas viejas sobre `INSTALL.md`, `scripts/*.sh`, `systemd/*.service`, `CLAUDE.md`, `docs/infrastructure-design.md`, `.gitignore` y los propios `Docker/docker-compose.*.yml` — cero coincidencias funcionales fuera de `.specs/`. Quedan 4 menciones prosaicas sin path literal (`docs/infrastructure-design.md` líneas 16/19/135, hablan genéricamente de "el Dockerfile" sin nombrar un archivo específico) y 1 en `CHANGELOG.md` línea 38 (entrada histórica de la versión 0.1.1, historial congelado — mismo criterio que no reescribir specs convergidos) — ninguna es una ruta rota, son prosa descriptiva. Los 2 comentarios en `scripts/staging-up.sh` y `scripts/restore-staging.sh` que mencionaban `Dockerfile.backup` sin prefijo también se corrigieron a `Docker/Dockerfile.backup` por consistencia total.
- [x] VERIFY US4 — **Confirmado con smoke real**: stack `monitoring` completo (6 de 7 servicios — `node-exporter` excluido por la misma limitación de entorno local ya documentada en 006, no relacionada al reorg) levantado exclusivamente con `Docker/docker-compose.monitoring.yml` + `env/.env.monitoring`, contra un stub `db` real. Resultado idéntico al smoke original de 006: Prometheus targets (`cadvisor`/`postgres-exporter-prod`/`prometheus` en `up`, `postgres-exporter-staging` en `down` como se espera sin staging activa), `postgres-exporter-prod` con conexión real establecida (`"Established new database connection" fingerprint=db:5432`), Grafana con datasources+alerting+dashboards provisionados sin errores. **Hallazgo pedido por el usuario tras ver este VERIFY, y bug real descubierto al aplicarlo**: el usuario pidió fijar el nombre de proyecto a `odoo-infrastructure` (le resultaba raro que pasara a `docker`). Al aplicarlo literal e idéntico en las 5 compose (`name: odoo-infrastructure`), un test real (`up` de `db` en `prod`, después `up` de `db` en `staging`) confirmó que Compose **destruye y reemplaza** el contenedor `db` de prod con el de staging (mismo `<project>-<service>` → mismo nombre de contenedor), dejándolo únicamente en `staging-net` — `pgbouncer` de prod perdería la `db` de producción si ambos stacks corrieran juntos. Este bug ya era latente antes del reorg (el nombre de proyecto por defecto también era el mismo para las 5 stacks, al vivir todas en la raíz) — nadie lo había probado en esta secuencia exacta. **Fix aplicado**: `name: odoo-infrastructure-<stack>` (uno distinto por compose file) en vez del literal idéntico — mismo prefijo de marca que pedía el usuario, sin colisión. Re-testeado: `prod` y `staging` conviven sin problema (`odoo-infrastructure-prod-db-1` / `odoo-infrastructure-staging-db-1`), los 5 `docker compose config -q` siguen pasando.
- [x] VERIFY No quedan `docker-compose.*.yml`, `Dockerfile*` ni `.env.*.example` a nivel raíz del repo — confirmado, `ls` sin coincidencias.
- [x] VERIFY No se crearon archivos fuera de los listados en "File Structure" de `plan.md` — confirmado con `git status`, coincide exactamente (renames + modificaciones esperadas).

---
name: repo-layout-reorg
code: PLAN-007
version: R00
date: 2026-07-13
---

# Plan: Reorganización de layout — `Docker/` y `env/`

## Approach

Mover los 5 `docker-compose.*.yml` + 2 `Dockerfile*` a `Docker/`, y las 5 plantillas `.env.*.example` a `env/` (la convención del `.env.<stack>` real también pasa a `env/`, por la clarification). El único punto técnico no trivial es que Compose resuelve `build:`, `volumes:` (bind mounts relativos) y `env_file:` contra el directorio del propio archivo de compose — al mover los 5 compose files un nivel adentro, cada `./config/...` pasa a `../config/...`, cada `env_file: .env.X` pasa a `env_file: ../env/.env.X`, y cada `build: .` pasa a la forma larga `{context: .., dockerfile: Docker/Dockerfile}` para que el build context siga siendo la raíz del repo (donde vive `addons/`, que el `Dockerfile` copia por `COPY addons/...`) y no `Docker/` mismo. `config/`, `systemd/`, `scripts/` y `addons/` no se mueven — solo se actualizan las rutas que otros archivos usan para apuntarles.

## Constitution Check

- **Tech stack**: sin cambios — mismas imágenes, mismos stacks, mismo Dockerfile multi-stage. Reorg puramente de layout.
- **Code principles aplicables**:
  - "Nunca usar `latest`" → no aplica, no se tocan tags de imagen.
  - "`odoo.conf` siempre `:ro`" → se preserva, solo cambia el path del mount (`../config/odoo.conf:ro`).
  - "`PGDATA` en subdirectorio del volumen" → no aplica, no se tocan variables de Postgres.
  - "El Makefile es la única interfaz operativa a partir de B010" → no implementado todavía; esta reorg es explícitamente la preparación para que B010 no tenga que tocar paths dos veces (mencionado en el spec como Non-Goal/motivación).
- Sin conflictos detectados.

## Architecture

```text
Antes                              Después
──────                             ───────
docker-compose.prod.yml            Docker/docker-compose.prod.yml
docker-compose.staging.yml         Docker/docker-compose.staging.yml
docker-compose.edge.yml            Docker/docker-compose.edge.yml
docker-compose.monitoring.yml      Docker/docker-compose.monitoring.yml
docker-compose.backup.yml          Docker/docker-compose.backup.yml
Dockerfile                         Docker/Dockerfile
Dockerfile.backup                  Docker/Dockerfile.backup

.env.prod.example                  env/.env.prod.example
.env.staging.example                env/.env.staging.example
.env.edge.example                  env/.env.edge.example
.env.monitoring.example            env/.env.monitoring.example
.env.backup.example                env/.env.backup.example
(.env.<stack> real, gitignored)    env/.env.<stack> (gitignored, misma exclusión, otra carpeta)

config/, systemd/, scripts/, addons/   sin cambios de ubicación
```

**Patrón de `build:` (prod + staging, ambos usan el mismo `Dockerfile`)**:
```yaml
# antes (compose en la raíz, contexto = raíz)
build: .

# después (compose en Docker/, contexto sigue siendo la raíz)
build:
  context: ..
  dockerfile: Docker/Dockerfile
```
Mismo patrón para `docker-compose.backup.yml` con `dockerfile: Docker/Dockerfile.backup`. El contexto `..` es necesario porque el `Dockerfile` hace `COPY addons/custom/repos.yaml`, `COPY addons/enterprise`, `COPY addons/oca` — rutas relativas a la raíz del repo, no a `Docker/`.

**Patrón de `env_file:`** (cada compose apunta al `env/` del repo, no al suyo propio):
```yaml
env_file: ../env/.env.<stack>
```

**Patrón de mounts relativos** (`config/` no se mueve):
```yaml
volumes:
  - ../config/odoo.conf:/etc/odoo/odoo.conf:ro
```

**Invocaciones directas de `docker build`** (fuera de compose, en `scripts/staging-up.sh` e `INSTALL.md` paso 2) mantienen el contexto `.` (ya corren con cwd = raíz del repo) y solo cambian el flag `-f`:
```bash
docker build -f Docker/Dockerfile.backup -t odoo-restore-tools:local .
docker build -f Docker/Dockerfile -t odoo-prod:$(git rev-parse --short HEAD) .
```

**`docker compose -f ...`** en todo comando (`scripts/*.sh`, `systemd/*.service`, `INSTALL.md`) pasa a `-f Docker/docker-compose.<stack>.yml`; siguen corriendo con cwd = raíz del repo, así que `../env/`/`../config/` dentro del propio compose ya resuelve — no hace falta `--env-file` extra en el CLI.

## File Structure

```text
odoo-infrastructure/
├── Docker/                                  ← nuevo directorio
│   ├── docker-compose.prod.yml              ← movido; build (context: .., dockerfile: Docker/Dockerfile), env_file: ../env/.env.prod, volume ../config/odoo.conf
│   ├── docker-compose.staging.yml           ← movido; mismo patrón, env_file: ../env/.env.staging (x4 servicios), volume ../config/odoo-staging.conf
│   ├── docker-compose.edge.yml               ← movido; env_file: ../env/.env.edge, volumes ../config/traefik*.yml
│   ├── docker-compose.monitoring.yml         ← movido; env_file: ../env/.env.monitoring (x2), volumes ../config/prometheus.yml, ../config/grafana/provisioning, ../config/loki-config.yml, ../config/promtail-config.yml
│   ├── docker-compose.backup.yml             ← movido; build (context: .., dockerfile: Docker/Dockerfile.backup), env_file: ../env/.env.backup
│   ├── Dockerfile                            ← movido, contenido sin cambios (COPY addons/... ya son relativos al contexto, que sigue siendo la raíz)
│   └── Dockerfile.backup                     ← movido, contenido sin cambios (COPY scripts/backup.sh idem)
├── env/                                      ← nuevo directorio
│   ├── .env.prod.example                     ← movido, contenido sin cambios
│   ├── .env.staging.example                  ← movido
│   ├── .env.edge.example                     ← movido
│   ├── .env.monitoring.example                ← movido
│   └── .env.backup.example                   ← movido
├── .gitignore                                ← modificado: .env.prod→env/.env.prod (+ staging/edge/backup/monitoring), docker-compose.override.yml→Docker/docker-compose.override.yml
├── scripts/
│   ├── staging-up.sh                         ← modificado: -f Docker/docker-compose.staging.yml, -f Docker/Dockerfile.backup, . ./env/.env.staging, --env-file env/.env.staging
│   ├── staging-down.sh                       ← modificado: -f Docker/docker-compose.staging.yml
│   ├── setup-backup-role.sh                  ← modificado: -f Docker/docker-compose.prod.yml, . ./env/.env.prod
│   └── setup-monitoring-role.sh              ← modificado: -f Docker/docker-compose.prod.yml, . ./env/.env.prod
├── systemd/
│   ├── odoo-backup.service                   ← modificado: ExecStart -f Docker/docker-compose.backup.yml
│   └── staging-teardown-boot.service         ← modificado: ExecStart -f Docker/docker-compose.staging.yml
├── INSTALL.md                                 ← modificado: todas las invocaciones docker/docker compose (~20) + todos los cp .env.X.example
├── CLAUDE.md                                  ← modificado: tabla de stacks y ejemplos de Makefile (roadmap) con paths Docker/
└── docs/infrastructure-design.md             ← modificado: tabla "stack | archivo | servicios" y las 2-3 menciones de comando literal (`docker compose -f docker-compose.backup.yml run --rm backup`)
```

`config/`, `systemd/*.service` (solo contenido, no ubicación), `scripts/*.sh` (solo contenido, no ubicación), `scripts/restore-staging.sh`, `scripts/anonymize-staging.sql`, `scripts/backup.sh`, `addons/` — sin cambios de ubicación.

## Data Model

N/A — reorg de archivos, sin modelo de datos.

## API / Interface Contracts

- **Invocación de cada stack** cambia de `docker compose -f docker-compose.<stack>.yml <acción>` a `docker compose -f Docker/docker-compose.<stack>.yml <acción>` — siempre corrida desde la raíz del repo (mismo cwd que hoy, ninguna instrucción pide `cd Docker/`).
- **Build directo de imágenes** cambia de `docker build .` (Dockerfile implícito en raíz) a `docker build -f Docker/Dockerfile .` (contexto explícito `.` = raíz, sin cambios).
- **Setup de credenciales** cambia de `cp .env.<stack>.example .env.<stack>` a `cp env/.env.<stack>.example env/.env.<stack>`.

## Dependencies

Ninguna — sin paquetes ni imágenes nuevas, reorg puro.

## Risks & Unknowns

- **Build context roto silenciosamente**: si `context:`/`dockerfile:` quedan mal emparejados, el build puede fallar recién al intentar `COPY addons/...` (no en el parseo de YAML) — la verificación en `implement` debe incluir un build real de la imagen `odoo` y de `Dockerfile.backup`, no solo `docker compose config -q` (que valida sintaxis pero no ejecuta el build).
- **Barrido incompleto de referencias**: el inventario ya relevado (grep) cubre `INSTALL.md`, `scripts/*.sh`, `systemd/*.service`, `CLAUDE.md`, `docs/infrastructure-design.md`, `.gitignore` y los propios compose files — pero conviene un grep final post-cambio (`grep -rn "docker-compose\.\|\.env\.\(prod\|staging\|edge\|monitoring\|backup\)\.example" . --include='*.sh' --include='*.md' --include='*.yml' --include='*.service'` excluyendo `.specs/`) para confirmar cero coincidencias residuales antes de cerrar.
- **`docker-compose.override.yml`** no existe como archivo real hoy — solo se actualiza su entrada en `.gitignore`; si en el futuro alguien lo crea a mano en la raíz (path viejo) por hábito, Compose no lo recogería desde `Docker/` — señalado como edge case en el spec, sin acción adicional posible más allá de la entrada correcta en `.gitignore`.
- **`.specs/001-006/`** mencionan las rutas viejas en su propio texto — intencionalmente no se tocan (Non-Goal del spec, historial congelado); quien lea specs viejos junto al código actual debe saber que el layout de archivos cambió en `007`.

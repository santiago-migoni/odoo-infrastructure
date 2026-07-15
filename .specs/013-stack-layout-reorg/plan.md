---
name: stack-layout-reorg
code: PLAN-013
version: R00
date: 2026-07-15
---

# Plan: Reorganización de layout por stack + imágenes Docker independientes

## Approach

`git mv` cada archivo de `config/`/`docker/`/`env/` hacia `<stack>/config|docker|env/`, duplicando `docker/Dockerfile` (prod↔staging) y triplicando `docker/Dockerfile.backup` (backup/staging/prod) como copias independientes idénticas al día uno. El único ajuste no trivial es el `build.context` de cada `docker-compose.yml` que buildea imagen propia: el compose pasa de vivir 1 nivel bajo la raíz (`docker/`) a vivir 2 niveles bajo la raíz (`<stack>/docker/`), así que `context: ..` deja de apuntar a la raíz del repo — hay que corregirlo a `context: ../..` para seguir pudiendo copiar `addons/`. Todo lo demás (`env_file:`, mounts de `config/`) mantiene la misma profundidad relativa (`<stack>/docker/` → `../env/`, `../config/` sigue siendo un nivel arriba, ahora dentro del propio stack) y no cambia de forma.

## Constitution Check

- **Naming Conventions (R07)**: implementa exactamente el layout `<stack>/docker/`, `<stack>/config/`, `<stack>/env/` ya definido. Alineado.
- **Code Principles (R07)**: "cada stack tiene su propia imagen Docker, sin excepciones compartidas" — este plan es la implementación directa: `Dockerfile`/`Dockerfile.tools` se duplican/triplican como archivos independientes, no symlinks ni includes.
- **Code Principles (R06)**: "Makefile es la interfaz operativa, un solo dispatcher como fuente de verdad" — solo se actualizan las tablas de paths dentro de `scripts/mk-dispatch.sh`, la arquitectura del dispatcher no cambia.
- **Tech stack**: no agrega dependencias — son movimientos de archivo (`git mv`) + ediciones de paths en YAML/shell ya existentes.

## Architecture

**El detalle que rompe todo si se hace mal**: hoy `docker/docker-compose.prod.yml` tiene `build: {context: .., dockerfile: docker/Dockerfile}` — `context: ..` sube 1 nivel desde `docker/` hasta la raíz del repo (necesario para `COPY addons/...` dentro del `Dockerfile`). Tras el reorg, el compose vive en `prod/docker/docker-compose.yml` — 2 niveles bajo la raíz. Si `context:` se deja en `..`, apuntaría a `prod/`, no a la raíz, y el build fallaría al no encontrar `addons/`. Fix: `context: ../..`, `dockerfile: prod/docker/Dockerfile` (path del Dockerfile relativo al nuevo context, que sigue siendo la raíz). El contenido del `Dockerfile` en sí **no cambia** — sus `COPY addons/...`/`COPY scripts/...` ya son relativos al build context, no a dónde vive el archivo físicamente.

Mismo fix aplica a `backup/docker/docker-compose.yml` (hoy buildea `docker/Dockerfile.backup`).

`env_file:`/mounts de `config/` **no** necesitan este fix — hoy son `../env/.env.<stack>` y `../config/<archivo>` desde `docker/` (1 nivel arriba + carpeta destino). Tras el reorg, desde `<stack>/docker/`, siguen siendo `../env/.env.<stack>` y `../config/<archivo>` (1 nivel arriba a `<stack>/`, después a la carpeta hermana) — la profundidad relativa entre el compose y su propio `env/`/`config/` no cambia, solo cambió de qué carpeta son hermanos.

**Scripts que buildean por fuera de compose** (`docker build -f ... .`, no `docker compose build`): `refresh-staging.sh` y `prod-db-restore.sh` ya hacen `cd "$(dirname "$0")/.."` al arrancar (quedan en la raíz del repo), así que su build context (`.`) ya es correcto sin tocar — solo cambia el flag `-f` al nuevo path del `Dockerfile.tools` correspondiente.

## File Structure

```text
prod/
├── docker/docker-compose.yml       ← git mv docker/docker-compose.prod.yml; fix context/dockerfile
├── docker/Dockerfile                ← git mv docker/Dockerfile (copia 1 de 2, idéntica al día uno)
├── docker/Dockerfile.tools          ← git mv docker/Dockerfile.backup (copia 1 de 3, idéntica al día uno)
├── config/odoo.conf.example         ← git mv config/odoo.conf.example
└── env/.env.prod.example            ← git mv env/.env.prod.example

staging/
├── docker/docker-compose.yml        ← git mv docker/docker-compose.staging.yml; fix context/dockerfile
├── docker/Dockerfile                ← copia 2 de 2 (duplicado, no mv — el archivo original ya se movió a prod/)
├── docker/Dockerfile.tools          ← copia 2 de 3 (duplicado)
├── config/odoo-staging.conf.example ← git mv config/odoo-staging.conf.example
└── env/.env.staging.example         ← git mv env/.env.staging.example

backup/
├── docker/docker-compose.yml        ← git mv docker/docker-compose.backup.yml; fix context/dockerfile
├── docker/Dockerfile                ← copia 3 de 3 (git mv docker/Dockerfile.backup acá, renombrado)
└── env/.env.backup.example          ← git mv env/.env.backup.example

edge/
├── docker/docker-compose.yml        ← git mv docker/docker-compose.edge.yml (sin build, sin fix de context)
├── config/traefik.yml               ← git mv
├── config/traefik-dynamic.yml       ← git mv
└── env/.env.edge.example            ← git mv

monitoring/
├── docker/docker-compose.yml        ← git mv docker/docker-compose.monitoring.yml (sin build)
├── config/prometheus.yml            ← git mv
├── config/loki-config.yml           ← git mv
├── config/promtail-config.yml       ← git mv
├── config/grafana/provisioning/     ← git mv (todo el subárbol)
└── env/.env.monitoring.example      ← git mv

scripts/mk-dispatch.sh               ← compose_file_for() y la línea literal de run-backup, nuevos paths
scripts/refresh-staging.sh           ← env/.env.staging → staging/env/.env.staging; docker-compose.staging.yml → staging/docker/docker-compose.yml; Dockerfile.backup → staging/docker/Dockerfile.tools
scripts/nuke-staging.sh              ← docker-compose.staging.yml → staging/docker/docker-compose.yml
scripts/prod-db-restore.sh           ← env/.env.backup, env/.env.prod, docker-compose.prod.yml, Dockerfile.backup → paths nuevos (prod/docker/Dockerfile.tools)
scripts/setup-backup-role.sh         ← env/.env.prod → prod/env/.env.prod; docker-compose.prod.yml → prod/docker/docker-compose.yml
scripts/setup-monitoring-role.sh     ← idem setup-backup-role.sh
systemd/odoo-backup.service          ← ExecStart= → backup/docker/docker-compose.yml
.gitignore                           ← paths de los 5 config/env reales, a <stack>/config/... y <stack>/env/...
INSTALL.md                           ← todas las rutas de comandos, paso por paso
CLAUDE.md                            ← tabla de arquitectura, ejemplos de paths
README.md                            ← tabla de arquitectura si menciona paths de archivos
```

`scripts/backup.sh`, `scripts/restore-staging.sh`, `scripts/anonymize-staging.sql`, `systemd/staging-refresh.service` (ya apunta solo a `scripts/refresh-staging.sh`, sin paths de compose/config): sin cambios.

## Data Model

N/A

## API / Interface Contracts

**Contrato de `compose_file_for()`** (`scripts/mk-dispatch.sh`): cambia de `"docker/docker-compose.$1.yml"` a `"$1/docker/docker-compose.yml"` — mismo contrato de entrada/salida (recibe el nombre del stack, devuelve el path del compose), ningún llamador necesita cambiar.

**Contrato de los `docker-compose.*.yml`**: `env_file:`, `volumes:` de config, nombres de servicio, healthchecks, límites de recursos — todos sin cambios de valor, solo de ubicación del archivo contenedor.

## Dependencies

Ninguna nueva — son movimientos de archivo + ediciones de paths en YAML/shell ya existentes.

## Risks & Unknowns

- **`build.context` es el punto de falla más fácil** (ver Architecture) — cada uno de los 3 composes con build propio (`prod`, `staging`, `backup`) necesita el fix `../..`, verificado con un build real (no solo `docker compose config -q`, que no ejecuta el build) durante `/implement`.
- **`.gitignore` tiene una entrada muerta**: `docker/docker-compose.override.yml` — no existe tal archivo hoy en el repo (verificado, cero referencias fuera del propio `.gitignore`). Se actualiza a un path coherente por si se usa a futuro, o se elimina si se confirma que no tiene uso — a decidir en `/tasks`.
- Los archivos reales gitignored (`config/odoo.conf`, `env/.env.prod`, etc.) que ya existen en el disco local (usados para testing en esta sesión) deben moverse a mano a su nueva ubicación como parte de la verificación — no se migran solos.

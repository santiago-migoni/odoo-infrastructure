---
name: imagen-docker-prod
code: PLAN-001
version: R03
date: 2026-07-10
---

# Plan: Imagen Docker + Stack de Producción

## Approach

Un `Dockerfile` propio (multi-stage) que empaqueta Odoo 19 Community + los addons custom (agregados en build-time vía `git-aggregator`, uno por categoría, pineados por commit/rama en `repos.yaml`), y un `docker-compose.prod.yml` con tres servicios (`odoo`, `db`, `pgbouncer`) sobre una única red interna de Docker, sin publicar puertos. La exposición temporal para pruebas vive en un `docker-compose.override.yml` gitignored, nunca en el compose versionado.

**Revisado tras T002 (segunda vuelta):** se descartaron los git submodules para `addons/custom` (13 categorías) por la fricción operativa que implican (detached HEAD, `--init --recursive`, commitear bumps de puntero a mano). En su lugar, `git-aggregator` (herramienta estándar del ecosistema OCA) agrega los repos de categoría en build-time desde un único `repos.yaml` versionado, manteniendo el mismo pin de reproducibilidad por commit sin esa fricción.

## Constitution Check

- **Tech stack**: Docker Compose, Odoo 19 Community, PostgreSQL, PgBouncer — coincide exactamente con lo definido en la constitución.
- **Code principles aplicables**: "ningún contenedor publica puertos al host"; "nunca usar `latest`"; "`list_db=False`/`proxy_mode=True` no negociables"; "RAM es el recurso más restrictivo" (sizing de esta feature debe respetar el presupuesto documentado).
- **Constraints**: servidor único de 14 GiB RAM compartido con staging/monitoring/backup (features futuras) — este stack por sí solo no debe asumir toda la RAM disponible; se ciñe al sizing ya fijado (prod: 3 workers, 1638/2048 MiB).
- Sin conflictos detectados.

## Architecture

```text
                     ┌───────────────────────────────────────┐
                     │        red interna Docker             │
                     │        (odoo-prod-net, bridge)        │
                     │                                       │
  (nada expuesto) ── │  odoo:8069/8072 ──▶ pgbouncer:6432 ──▶│ db:5432
                     │                                       │
                     └───────────────────────────────────────┘
```

- `odoo` no habla directo con `db` — siempre a través de `pgbouncer` (host/puerto de conexión en `odoo.conf` apunta a `pgbouncer:6432`).
- `db` no expone su puerto 5432 fuera de la red interna.
- Sin `docker-compose.override.yml`, ningún servicio es alcanzable desde el host. Con el override (gitignored, uso local del operador), `odoo` queda mapeado a `127.0.0.1:8069` únicamente.

## File Structure

```text
odoo-infrastructure/
├── Dockerfile                          ← nuevo, multi-stage. Stage `build`: instala `git-aggregator` (pip, `--break-system-packages`) y corre `gitaggregate -c repos.yaml` para clonar los addons custom pineados; stage final: `FROM odoo:19.0-20260630`, copia el resultado vía `COPY --from=build`, copia `addons/enterprise`/`addons/oca`, instala `requirements.txt` vía `find | xargs` (no `find -exec`, que no propaga fallos de `pip3`) con `--break-system-packages` (PEP 668), corre como odoo (UID 101). `git`/`pip`/`git-aggregator` no quedan en la imagen final.
├── docker-compose.prod.yml             ← nuevo. Servicios odoo/db/pgbouncer, sin ports:, healthchecks, resource limits, volúmenes con nombre
├── docker-compose.override.yml.example ← nuevo. Plantilla comentada del mapeo 127.0.0.1:8069 (el .yml real, sin el .example, va gitignored)
├── config/
│   └── odoo.conf                       ← nuevo. db_name=odoo (requerido: sin él, el contenedor no sabe contra qué base operar y /web/health nunca responde), workers=3, max_cron_threads=2, limit_memory_soft/hard, list_db=False, proxy_mode=True, addons_path (sin cambios: sigue apuntando a /mnt/custom-addons/<categoria> por cada una, sea cual sea el mecanismo que las puebla)
├── addons/
│   ├── custom/
│   │   └── repos.yaml                  ← nuevo (reemplaza los 13 placeholders `.gitkeep` de T002). Config de `git-aggregator`: una entrada por categoría con `remotes`/`target`/`merges` (pin a commit o rama). Sin entradas reales todavía — ninguna URL de categoría disponible, ni `sales`. Se completa a medida que existan.
│   ├── enterprise/.gitkeep             ← nuevo. Vacío a propósito — addons_path ya lo referencia, listo para cuando haya licencia
│   └── oca/.gitkeep                    ← nuevo. Vacío a propósito — listo para submódulos OCA futuros
├── .env.prod.example                   ← nuevo. Plantilla de variables (POSTGRES_USER, POSTGRES_PASSWORD, etc.) — el .env.prod real gitignored
├── .gitignore                          ← modificado. Agrega: docker-compose.override.yml, .env.prod, .env.staging
└── INSTALL.md                          ← modificado (existe vacío). Instrucciones de build manual: docker build + verificación de tag/usuario
```

## Data Model

N/A — el modelo de datos de negocio lo define Odoo mismo; esta feature no introduce esquema propio.

## API / Interface Contracts

Contrato de variables de entorno entre servicios (todo vía `.env.prod`, referenciado por `env_file`):

- **`odoo`**: `HOST=pgbouncer`, `PORT=6432`, `USER=${POSTGRES_USER}`, `PASSWORD=${POSTGRES_PASSWORD}` (conexión a DB únicamente — el resto de la config vive en `odoo.conf`, montado `:ro`).
- **`db`** (imagen oficial `postgres:16-alpine`): `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `PGDATA=/var/lib/postgresql/data/pgdata` (subdirectorio, no el mount point), `POSTGRES_INITDB_ARGS="--locale-provider=icu --icu-locale=en-US"` (obligatorio — ver "Riesgos", evita el bug de collation de Alpine).
- **`pgbouncer`** (imagen `edoburu/pgbouncer`, configurable por env vars): `DB_HOST=db`, `DB_PORT=5432`, `DB_USER`, `DB_PASSWORD`, `POOL_MODE=transaction`, `DEFAULT_POOL_SIZE=20`, `MAX_CLIENT_CONN=200`, `LISTEN_PORT=6432`, `AUTH_TYPE=scram-sha-256` (obligatorio — ver "Riesgos" para por qué).

## Dependencies

- `odoo:19.0-20260630` (build oficial fechado, no el tag flotante `19.0` — pinea a un build concreto de Docker Hub; actualizar al tag `19.0-YYYYMMDD` más reciente disponible al momento del build real).
- `postgres:16-alpine` (oficial, Docker Hub) — versión mayor confirmada compatible (Odoo 19 requiere Postgres 13+, recomienda 15+; 16 cae dentro de lo recomendado). Variante Alpine por tamaño de imagen.
- `edoburu/pgbouncer` (imagen mantenida, configurable 100% por variables de entorno — evita mantener un `pgbouncer.ini` propio a mano).
- `git-aggregator` (pip, herramienta estándar OCA) — solo en el stage `build` del Dockerfile, no queda en la imagen final. Reemplaza a git submodules para `addons/custom`.
- Sin dependencias nuevas de lenguaje/paquetes fuera de lo que cada addon custom declare en su propio `requirements.txt`.

## Risks & Unknowns

Los tres riesgos identificados en el borrador anterior quedaron investigados y resueltos (no solo mitigados):

- **PgBouncer ↔ Postgres 16 (auth `scram-sha-256`) — resuelto.** Verificado el `entrypoint.sh` de `edoburu/pgbouncer`: con `AUTH_TYPE=scram-sha-256`, el script escribe el password en texto plano en `userlist.txt` (solo dentro del contenedor, generado en runtime, nunca en disco del host ni en el repo) y es PgBouncer quien completa el handshake SCRAM contra Postgres usando ese password — es el mecanismo soportado, no un workaround. Acción: setear `AUTH_TYPE=scram-sha-256` en el servicio `pgbouncer` (ya reflejado en "API / Interface Contracts").
- **Odoo 19 ↔ Postgres 16 — resuelto.** Confirmado por la documentación de Odoo 19: mínimo soportado es Postgres 13, recomendado 15+. Postgres 16 cae cómodo dentro de lo recomendado.
- **Directorios vacíos en `addons_path` (`enterprise`, `oca`, y las 13 categorías de `custom`) — cosmético, confirmado en implementación.** Corrección respecto al análisis previo: Odoo sí loguea un `WARNING` (`invalid addons directory '...', skipped`) por cada entrada de `addons_path` que existe pero está vacía — la conclusión anterior ("no queda ningún log") era incorrecta. No bloquea el arranque ni afecta funcionalidad: Odoo simplemente excluye esa entrada de su búsqueda real de módulos hasta que deje de estar vacía.
- **Collation rota en `postgres:16-alpine` — mitigado.** Alpine usa `musl` en vez de `glibc`; antes de Postgres 15, `musl` no soporta `LC_COLLATE` y el ordenamiento de texto cae silenciosamente a bytewise (`C`) sin importar el locale seteado. Desde Postgres 15+ (16 incluida) se soluciona con el locale provider ICU. Acción: `POSTGRES_INITDB_ARGS="--locale-provider=icu --icu-locale=en-US"` en `db` (ya reflejado en "API / Interface Contracts") — sin esto, la base inicializa con collation `C` en vez del locale esperado.

Sin riesgos abiertos pendientes de validar en implementación.

**Riesgo nuevo (git-aggregator) — a validar en implementación:**
- **`repos.yaml` sin entradas reales (ninguna URL de categoría disponible todavía).** `gitaggregate -c repos.yaml` debería ser un no-op seguro con cero repos configurados, dejando `/mnt/custom-addons` vacío pero existente (no debe romper el `COPY --from=build` del stage final). A confirmar con un build real antes de dar la tarea por cerrada.
- **Build necesita red para clonar en cache-miss.** Con submodules el contenido ya estaba en disco antes del build; con `git-aggregator` el `RUN gitaggregate` clona en el momento del build. Docker cachea la capa mientras `repos.yaml` no cambie, así que en la práctica esto solo importa cuando se pinea/actualiza un commit — el mismo momento en que con submodules habría hecho falta un `git pull` de todos modos. Sin mitigación adicional necesaria, es un trade-off aceptado.

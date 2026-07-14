---
name: monitoring-stack
code: PLAN-006
version: R00
date: 2026-07-13
---

# Plan: Stack `monitoring`

## Approach

Un `docker-compose.monitoring.yml` (4to stack real) con 7 servicios siempre-arriba: `prometheus`, `grafana`, `loki`, `promtail`, `cadvisor`, `node-exporter`, `postgres-exporter-prod`. Todo vive en `odoo-shared` (la red interna existente) para que Prometheus scrapee los exporters por DNS de Docker, `postgres-exporter-prod` alcance la `db` de prod, y Traefik rutee a `grafana:3000` — sin publicar puertos. Toda la config es declarativa y versionada (scrape de Prometheus, retención de Loki, discovery de Promtail, datasources/dashboards/alertas de Grafana provisionados por archivo). Se reutiliza la imagen de `postgres-exporter` ya elegida en 005 y el patrón de router de Traefik ya usado para odoo/staging. Operado con `docker compose` directo hasta que el Makefile (roadmap B010) lo envuelva.

## Constitution Check

- **Tech stack**: `monitoring` es el stack ya previsto en la constitución con exactamente estos servicios (Prometheus + Grafana + cAdvisor + node-exporter + postgres-exporter + Loki + Promtail). Todas las imágenes se pinean por versión (nunca `latest`). ✓
- **Code principles aplicables**:
  - "Ningún contenedor publica puertos al host" → cero `ports:`; Prometheus scrapea por red interna, Grafana se alcanza solo por Traefik. ✓
  - "RAM es el recurso más restrictivo" → cada servicio con `mem_limit` según la tabla de `docs/infrastructure-design.md` (techo, no reserva); el total baseline queda ~10.1 GiB / peak ~11.7 GiB, ya presupuestado. ✓
  - "Nunca usar `latest`" → todas las imágenes con tag de versión fijo. ✓
  - "El Makefile es la única interfaz operativa **a partir de B010**" → hasta entonces se opera con `docker compose` directo, documentado en INSTALL.md (permitido explícitamente por la constitución para features previas a #6). ✓
  - Grafana detrás de reverse proxy → `GF_SERVER_ROOT_URL` fijado (análogo a `proxy_mode` de Odoo), consistente con "servicios expuestos operan detrás del edge". ✓
- Sin conflictos detectados.

## Architecture

```text
                         ┌─────────────── odoo-shared (red interna existente) ───────────────┐
                         │                                                                    │
node-exporter (host RAM/CPU/disk) ─┐                                                          │
cAdvisor (por contenedor) ─────────┤──scrape──▶ Prometheus ──query──▶ Grafana ──▶ Traefik ──▶ cloudflared
postgres-exporter-prod (db prod) ──┘   (15d)      :9090        :3000     (grafana.miempresa.com,
                         │                                                 detrás de Cloudflare Access)
Promtail (docker socket) ──push──▶ Loki (15d) ──datasource──▶ Grafana                         │
                         │                                                                    │
                         └────────────────────────────────────────────────────────────────────┘
                                    │
                         staging-net (Prometheus también se une aquí, como Traefik)
                                    └──scrape──▶ postgres-exporter-staging  (up si staging activa, down si no)

Grafana Alerting ──(SMTP)──▶ email del operador   [3 reglas: RAM host >85%/5m · contenedor caído · Postgres sin conexiones]
```

- **Red**: todos los servicios de `monitoring` se unen a `odoo-shared` (external, ya creada en bootstrap). Prometheus scrapea `node-exporter:9100`, `cadvisor:8080`, `postgres-exporter-prod:9187` y a sí mismo por DNS interno. Grafana consulta `http://prometheus:9090` y `http://loki:3100`. Traefik (ya en `odoo-shared`) rutea a `grafana:3000`. Ningún `ports:`.
- **Scrape de staging (edge case del spec)**: Prometheus se une **también** a `staging-net` (mismo patrón que Traefik en el edge) para poder scrapear `postgres-exporter-staging:9187` cuando staging está activa; el target aparece `down` cuando no. Las métricas *de contenedor* de staging ya llegan igual por cAdvisor (lee del kernel/Docker del host, no depende de la red). Ver Risks — es la única concesión de aislamiento y es acotada (Prometheus solo hace GET al endpoint del exporter).
- **postgres-exporter-prod (US1)**: misma imagen que staging (`quay.io/prometheuscommunity/postgres-exporter:v0.15.0`). Se conecta directo a `db:5432` (no a PgBouncer) con un **rol de solo lectura dedicado** (`monitoring`, con `pg_monitor`), no el superusuario — creado por `scripts/setup-monitoring-role.sh` (mismo patrón que `setup-backup-role.sh`). El DSN vive en `.env.monitoring`.
- **Prometheus (US1, US5)**: `config/prometheus.yml` con los jobs de arriba; retención `--storage.tsdb.retention.time=15d`; volumen con nombre `prometheus-data`. `mem_limit: 2g`.
- **Loki + Promtail (US2)**: Loki en modo monolítico, `config/loki-config.yml`, retención 15 días (`limits_config.retention_period: 360h` + compactor con retención habilitada); volumen `loki-data`. Promtail descubre contenedores por el socket de Docker (`docker_sd_configs`, socket montado `:ro`) y los etiqueta por nombre de contenedor y stack; `config/promtail-config.yml` + volumen para posiciones. No usa el driver de logging de Docker (evita un plugin en el host).
- **Grafana (US3)**: provisioning declarativo — datasources (Prometheus + Loki) y dashboards base (host, contenedores, Postgres) bajo `config/grafana/provisioning/`. `GF_SERVER_ROOT_URL=https://grafana.miempresa.com`, admin y SMTP desde `.env.monitoring`; volumen `grafana-data`. Traefik agrega un router `Host(grafana.miempresa.com) → grafana:3000` (un solo router; el WebSocket de Grafana Live va por el mismo puerto 3000, no necesita el split que Odoo hace con 8072). Cloudflare Access se configura **manual** en el panel (documentado en INSTALL.md); el login propio de Grafana es la segunda capa.
- **Alertas (US4)**: Grafana Unified Alerting provisionado por archivo (`config/grafana/provisioning/alerting/`): 3 reglas — RAM host >85% sostenido 5 min (métrica de node-exporter), contenedor esperado caído (`container_last_seen`/`up` de cAdvisor/exporters), Postgres cerca de agotar conexiones (`pg_settings_max_connections - pg_stat_activity_count` ≈ 0, de postgres-exporter) — un contact point SMTP y una notification policy. Credenciales SMTP desde `.env.monitoring`.
- **Siempre-arriba (US5)**: todos con `restart: unless-stopped`; datos en volúmenes con nombre (persisten reinicios, a diferencia de staging). Sin efímero, sin systemd — el stack se levanta una vez y queda.

## File Structure

```text
odoo-infrastructure/
├── docker-compose.monitoring.yml   ← nuevo. 7 servicios, red odoo-shared (+ staging-net solo en prometheus), volúmenes prometheus-data/loki-data/grafana-data, mem_limit por servicio (prometheus 2g, grafana 1.5g, loki 2g, cadvisor 300m, node-exporter 200m, promtail 128m, postgres-exporter-prod 64m)
├── config/
│   ├── prometheus.yml              ← nuevo. Jobs: prometheus, node-exporter, cadvisor, postgres-exporter-prod, postgres-exporter-staging; retención 15d por flag en el compose
│   ├── loki-config.yml             ← nuevo. Monolítico, retención 360h (15d), compactor con retención
│   ├── promtail-config.yml         ← nuevo. docker_sd_configs por socket :ro, relabel a container/stack, push a loki:3100
│   └── grafana/provisioning/
│       ├── datasources/datasources.yml   ← nuevo. Prometheus (default) + Loki
│       ├── dashboards/dashboards.yml     ← nuevo. Provider que carga los .json de abajo
│       ├── dashboards/host.json          ← nuevo. RAM/CPU/disk del host (node-exporter)
│       ├── dashboards/containers.json    ← nuevo. Uso por contenedor (cAdvisor)
│       ├── dashboards/postgres.json      ← nuevo. Conexiones/actividad de Postgres prod
│       └── alerting/alerting.yml         ← nuevo. 3 reglas + contact point SMTP + notification policy
├── config/traefik-dynamic.yml      ← modificado. Agrega router `grafana` (Host grafana.miempresa.com → grafana:3000) + su service
├── scripts/setup-monitoring-role.sh ← nuevo. Crea el rol de solo lectura `monitoring` (pg_monitor) en la db de prod, idempotente (patrón de setup-backup-role.sh)
├── .env.monitoring.example         ← nuevo. DATA_SOURCE_NAME del exporter, GF_SECURITY_ADMIN_*, GF_SMTP_* — el .env.monitoring real gitignored
├── .gitignore                      ← modificado. Agrega .env.monitoring
└── INSTALL.md                      ← modificado. Bootstrap del stack, alta del rol monitoring, hostname grafana.miempresa.com en el Tunnel + política de Cloudflare Access, ciclo up/down con docker compose directo
```

## Data Model

N/A — no crea modelo propio. Lo único que toca el esquema es `setup-monitoring-role.sh` (crea un rol de Postgres de solo lectura); las métricas y logs son series temporales en los volúmenes de Prometheus/Loki, no un modelo relacional.

## API / Interface Contracts

- **Operación (hasta B010)**: `docker compose -f docker-compose.monitoring.yml up -d` / `... down` / `... logs -f <servicio>` / `... up -d --force-recreate grafana`. Documentado en INSTALL.md; los targets `monitoring-*` del Makefile llegan con B010.
- **Endpoints internos scrapeados** (no expuestos al host): `node-exporter:9100/metrics`, `cadvisor:8080/metrics`, `postgres-exporter-prod:9187/metrics`, `postgres-exporter-staging:9187/metrics`, `prometheus:9090`.
- **Superficie externa**: solo `https://grafana.miempresa.com` (vía cloudflared → Traefik → grafana:3000), detrás de Cloudflare Access + login de Grafana.

## Dependencies

Imágenes nuevas, todas pineadas (nunca `latest`); `postgres-exporter` ya estaba en uso desde 005:

- `prom/prometheus:v2.55.1`
- `grafana/grafana:11.4.0`
- `grafana/loki:3.3.2`
- `grafana/promtail:3.3.2` (misma versión que Loki)
- `gcr.io/cadvisor/cadvisor:v0.49.1`
- `quay.io/prometheus/node-exporter:v1.8.2`
- `quay.io/prometheuscommunity/postgres-exporter:v0.15.0` (ya en `docker-compose.staging.yml`)

Sin dependencias nuevas fuera de estas imágenes. (Versiones exactas a confirmar contra el último patch estable al implementar.)

## Risks & Unknowns

- **Loki/Promtail/postgres-exporter con memory leak** (issues documentados) → `mem_limit` como techo + `restart: unless-stopped`: si crecen, mueren por OOM y reinician, no se comen la RAM del host; se detecta como reinicios en las métricas. Loki `mem_limit: 2g` contiene el "Normal" (~1.5 GiB) pero puede matar queries pesadas no optimizadas — aceptable a esta escala, subir el techo si aparece.
- **Prometheus unido a `staging-net`** debilita levemente el aislamiento del entorno staging (única concesión). Alternativa si se prefiere aislamiento estricto: dropear el scrape de `postgres-exporter-staging` — las métricas de contenedor de staging igual llegan por cAdvisor. Decisión tomada: incluirlo, porque el spec lo pide y el costo es un GET al endpoint del exporter.
- **cAdvisor/node-exporter dependen de rutas del host** (`/`, `/sys`, `/proc`, `/var/lib/docker/`, socket de Docker) → montarlas `:ro` con las rutas reales de `serverdipleg`; verificar en el primer up que node-exporter reporta la RAM total real (14 GiB) y no la del contenedor.
- **Cloudflare Access se aprovisiona manual** → riesgo de dejar Grafana expuesto sin Access si se configura mal el hostname del Tunnel. Mitigación: runbook en INSTALL.md + el login propio de Grafana como segunda capa. (Fuera de alcance como código, por clarification.)
- **Lista exacta de "contenedores esperados"** para la alerta de caída (¿solo prod: odoo/db/pgbouncer/traefik/cloudflared? ¿también los de monitoring?) — [NEEDS CLARIFICATION en fase tasks/implement, no bloquea el plan]: se define al escribir la regla en `alerting.yml`; arranca con el set de prod + edge.
- **`docs/infrastructure-design.md`** marca hoy estos servicios como "diseño, no implementado" con `mem_limit` "a definir" — al cerrar la feature conviene actualizar esas filas a "implementado (006)" con los `mem_limit` reales (tarea menor de docs, no del código del stack).

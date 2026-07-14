---
name: staging
code: PLAN-005
version: R00
date: 2026-07-12
---

# Plan: Stack `staging` efímero

## Approach

Un `docker-compose.staging.yml` (5to stack real) con `odoo`, `db`, `pgbouncer`, `postgres-exporter`, todo en una red propia aislada `staging-net` (externa, creada en bootstrap junto a `odoo-shared`). El Odoo de staging **no** toca `odoo-shared`, así no puede resolver la `db` de prod; Traefik (en `edge`) se une a ambas redes para rutear. La orquestación vive en scripts versionados (`staging-up.sh`/`staging-down.sh`/`staging-extend.sh`), operados con comandos directos hasta que el Makefile (roadmap #6) los envuelva. El restore reutiliza la imagen `Dockerfile.backup` (ya trae `restic 0.18` + cliente `pg`) vía un script de restore corrido con `--entrypoint`. El orden crítico (restore → anonimización → recién Odoo) y el teardown duro (timer transiente de systemd + servicio oneshot de boot) son el corazón de la seguridad de la feature.

## Constitution Check

- **Tech stack**: `staging` es el stack ya previsto en la constitución (`odoo`, `db`, `pgbouncer`, `postgres-exporter`). Reutiliza imágenes ya en uso (`postgres:16-alpine`, `edoburu/pgbouncer`, la imagen propia de Odoo, `Dockerfile.backup` para restore). Falta elegir la imagen de `postgres-exporter` — ver Dependencies.
- **Code principles aplicables**:
  - "Staging es réplica fiel de prod, no un modo distinto" → `odoo-staging.conf` con workers (1), sin `dev_mode`, mismo split de longpolling. ✓
  - "Staging es efímera, `down -v` al terminar, no hay staging siempre arriba" → teardown duro auto-forzado + boot teardown. ✓
  - "`list_db = False` y `proxy_mode = True` no negociables en entornos expuestos" → staging **está** expuesta (`staging.miempresa.com`), así que su `odoo.conf` los incluye obligatoriamente. ✓
  - "Redes Docker aisladas entre entornos" → `staging-net` aislada, solo Traefik puentea. ✓
  - "RAM es el recurso más restrictivo" → sizing reducido (1 worker `hard=682MiB`, `shared_buffers=512MiB`), ya contemplado en el escenario Peak del presupuesto. ✓
  - "`odoo.conf` siempre `:ro`" y "`PGDATA` en subdirectorio del volumen" → se replica el patrón de prod. ✓
  - "Todo backup = DB + filestore juntos" → el restore restaura ambos. ✓
- Sin conflictos detectados.

## Architecture

```text
Operador ──▶ scripts/staging-up.sh
                  │
                  ├─ ¿staging ya activa? → staging-down.sh (down -v)   [teardown + fresh]
                  ├─ up -d db pgbouncer                                (staging-net)
                  ├─ restore-staging.sh (imagen Dockerfile.backup, --entrypoint):
                  │     restic restore latest → carga db.sql en odoo_staging (psql)
                  │     + copia filestore  odoo/ → odoo_staging/  (rename por db_name)
                  ├─ anonymize-staging.sql  (psql, ANTES de Odoo)     ◀── orden crítico
                  ├─ up -d odoo postgres-exporter
                  └─ systemd-run --on-active=3h --unit=odoo-staging-teardown → staging-down.sh

staging.miempresa.com ──▶ cloudflared ──▶ Traefik (odoo-shared + staging-net)
                                              ├─ /websocket → odoo-staging:8072
                                              └─ resto      → odoo-staging:8069

Reinicio del server ──▶ systemd staging-teardown-boot.service (oneshot) ──▶ down -v  (no-op si no hay nada)
```

- **Red aislada**: `staging-net` se crea como red externa en bootstrap (`docker network create staging-net`), igual que `odoo-shared`. `docker-compose.staging.yml` la referencia como externa; `docker-compose.edge.yml` agrega `staging-net` al servicio `traefik` (que queda en ambas redes). Prod sigue solo en `odoo-shared`. Como Traefik está en las dos redes y ambos entornos tienen un servicio `odoo`, el Odoo de staging usa un **alias/nombre distinto** (`odoo-staging`) para evitar ambigüedad de DNS — los routers de Traefik apuntan a `http://odoo-staging:8069/8072`.
- **Restore reutilizando la imagen de backup**: `restore-staging.sh` corre dentro de `Dockerfile.backup` (`--entrypoint`), montando el repo restic local (`/srv/odoo-backups:ro`), el volumen `odoo-data-staging` y la red `staging-net` (para alcanzar la `db` de staging). Hace `restic restore latest --target`, carga el `db.sql` en la base `odoo_staging` con `psql`, y copia el filestore restaurado de `filestore/odoo/` a `filestore/odoo_staging/` (el `db_name` de staging es distinto, Odoo busca el filestore bajo ese nombre). Restore **solo desde el repo local** (`RESTIC_REPOSITORY_LOCAL`), nunca R2.
- **Orden crítico (US1)**: `staging-up.sh` bajo `set -e` — si el restore o la anonimización fallan, el script sale sin llegar al `up -d odoo`. La `db`/`pgbouncer` quedan arriba pero sin un Odoo vivo sobre datos sin anonimizar; el operador puede re-correr `staging-up` (que hace teardown + fresh) o `staging-down`.
- **Anonimización (US1)**: `anonymize-staging.sql` con el set fijo del design doc — `UPDATE ir_mail_server SET active=false`; passwords de `res_users` a random; `UPDATE res_partner SET email='staging+'||id||'@example.com'`; payment providers deshabilitados; URLs de webhooks limpiadas en `ir_config_parameter`; crons de mail desactivados. Corre con `psql` contra `odoo_staging` antes del `up -d odoo`.
- **Teardown duro (US4)**: `staging-up` programa un timer transiente `systemd-run --on-active=3h --unit=odoo-staging-teardown` que dispara `staging-down.sh`. `staging-extend.sh` para el timer y lo re-arma con otras ~3h. Los timers transientes **no** sobreviven un reinicio → cubierto por `staging-teardown-boot.service` (oneshot, `WantedBy=multi-user.target`, `After=docker.service`) que hace `down -v` incondicional en cada boot (no-op si staging no está arriba).
- **`postgres-exporter` (US5)**: definido en `docker-compose.staging.yml`, no en `monitoring` — nace y muere con el stack, sin dejar un target permanentemente caído en Prometheus.

## File Structure

```text
odoo-infrastructure/
├── docker-compose.staging.yml   ← nuevo. odoo(-staging) + db + pgbouncer + postgres-exporter, red staging-net (externa), volúmenes db-data-staging + odoo-data-staging (NO externos: efímeros, se destruyen con down -v), sizing reducido
├── config/odoo-staging.conf     ← nuevo. Igual estructura que config/odoo.conf pero db_name=odoo_staging, workers=1, limit_memory_soft=572522496 (546MiB), limit_memory_hard=715128832 (682MiB); list_db=False, proxy_mode=True (expuesta)
├── scripts/
│   ├── staging-up.sh            ← nuevo. Teardown-si-activa → up db/pgbouncer → restore → anonimizar → up odoo/exporter → armar timer de teardown
│   ├── staging-down.sh          ← nuevo. down -v + cancelar el timer de teardown
│   ├── staging-extend.sh        ← nuevo. Re-armar el timer de teardown (~3h más)
│   ├── restore-staging.sh       ← nuevo. Corre en la imagen Dockerfile.backup: restic restore local → psql load en odoo_staging + copia filestore odoo/→odoo_staging/
│   └── anonymize-staging.sql    ← nuevo. Set fijo de anonimización (mail off, passwords random, emails reescritos, payment/webhooks off, crons de mail off)
├── systemd/
│   └── staging-teardown-boot.service ← nuevo. Oneshot en boot: down -v incondicional de staging
├── config/traefik-dynamic.yml   ← modificado. Agrega routers odoo-staging (Host staging.miempresa.com → :8069) y odoo-staging-ws (+ /websocket → :8072), reusando el middleware odoo-buffering
├── docker-compose.edge.yml      ← modificado. Traefik se une también a staging-net (external)
├── .env.staging.example         ← nuevo. Credenciales de db/pgbouncer staging, RESTIC_PASSWORD + RESTIC_REPOSITORY_LOCAL para el restore, DSN de postgres-exporter — el .env.staging real gitignored (ya en .gitignore)
└── INSTALL.md                   ← modificado. Bootstrap de staging-net, ruta de Tunnel para staging.miempresa.com, ciclo staging-up/extend/down, instalación del boot teardown service
```

## Data Model

N/A — opera sobre el esquema de Odoo restaurado desde prod; la anonimización son `UPDATE`s sobre tablas existentes, sin modelo propio.

## API / Interface Contracts

- **`scripts/staging-up.sh`** — contrato de comportamiento: si staging ya está activa hace teardown + fresh; bajo `set -e` nunca llega a `up -d odoo` si el restore o la anonimización fallan; deja armado el timer de teardown a ~3h.
- **`config/odoo-staging.conf`** — `db_name=odoo_staging`, `workers=1`, `max_cron_threads=1`, `limit_memory_soft=572522496`, `limit_memory_hard=715128832`, `list_db=False`, `proxy_mode=True`, mismo `addons_path` que prod.
- **`docker-compose.staging.yml`** — servicios en `staging-net` (externa); `odoo` con alias `odoo-staging`; `db` con `mem_limit` acorde (~1g), `shared_buffers=512MB`; volúmenes `*-staging` locales (no externos, para que `down -v` los destruya). Traefik NO se declara acá (vive en edge).
- **Routers de Traefik** (en `traefik-dynamic.yml`): `odoo-staging-ws` (priority 100, Host+`/websocket` → `odoo-staging:8072`) y `odoo-staging` (priority 1, Host → `odoo-staging:8069`), ambos con `odoo-buffering`.

## Dependencies

- `postgres:16-alpine`, `edoburu/pgbouncer`, imagen propia de Odoo, `Dockerfile.backup` — todas ya en uso, sin agregar nada nuevo.
- **`postgres-exporter`**: imagen nueva a fijar — `quay.io/prometheuscommunity/postgres-exporter` (pineada a una versión concreta, confirmada durante implementación). Es la única dependencia nueva; ya estaba prevista en la constitución (monitoring), acá solo se adelanta su definición al compose de staging.
- Herramientas del host: `systemd-run`/`systemctl` (timers transientes) — nativas de systemd, sin instalar nada.

## Risks & Unknowns

- **Rename del filestore `odoo/` → `odoo_staging/` en el restore.** El backup guarda el filestore de prod bajo `filestore/odoo/` (db_name de prod), pero staging usa `db_name=odoo_staging` y Odoo busca el filestore bajo ese nombre. `restore-staging.sh` debe copiarlo al path renombrado — a validar con un restore real que los adjuntos aparezcan en staging.
- **Ambigüedad de DNS con Traefik en dos redes.** Traefik en `odoo-shared` + `staging-net`, ambos con un `odoo`. Se mitiga con el alias `odoo-staging`; a confirmar en test real que Traefik resuelve `odoo-staging` a la instancia correcta y `odoo` (prod) sigue intacto.
- **Timers transientes vs reinicio.** `systemd-run --on-active` no sobrevive reboot; el `staging-teardown-boot.service` lo cubre. A validar en Linux real (no macOS) con `systemd-analyze verify` y un ciclo up → simular boot → confirmar `down -v`.
- **Exhaustividad de la anonimización.** El set del design doc cubre mail/pagos/webhooks/crons; puede faltar algún vector (ej. tokens IAP, cola `mail.mail` ya encolada, adjuntos con PII). Se parte del set documentado y se revisa contra una base real restaurada en implementación; cualquier hueco se corrige antes de exponer staging.
- **Sizing de `postgres-exporter` y `db` de staging — validación empírica.** Los números salen del presupuesto de RAM (design doc), a confirmar con `docker inspect` + carga real una vez implementado, como en features anteriores.

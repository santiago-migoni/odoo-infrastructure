# Infraestructura Odoo — Diseño de Producción

Documento de diseño construido por sesión de /grilling. Basado en principios de [oec.sh](https://oec.sh): self-hosted, "bring your own cloud", PostgreSQL tuneado + connection pooling, backups automatizados con rotación GFS a storage S3-compatible, reverse proxy + SSL, y monitoring.

## Decisiones

### Topología general
- **Modelo:** single-tenant — una instancia de producción + una de staging (no multi-tenant).
- **Servidores:** compartidos — prod y staging en el mismo servidor (por costos). Implica: stacks Docker Compose separados por entorno, límites de recursos (CPU/RAM) por contenedor para que staging no pueda afectar a prod, y redes Docker aisladas entre entornos.
- **Hosting:** on-premise (servidor físico propio, no cloud/VPS). Implica: sin servicios gestionados de un proveedor cloud — todo (backups offsite, red, energía, hardware) es responsabilidad propia. Backups deben salir del sitio (storage S3-compatible externo) para cubrir el riesgo de desastre físico local.
- **Exposición a internet:** Cloudflare Tunnel (`cloudflared`). No se abren puertos en el router; SSL/TLS gestionado por Cloudflare edge; IP real del servidor oculta.
- **Reverse proxy interno:** Traefik (ruteo por hostname vía labels de Docker; `cloudflared` apunta a Traefik, no a cada servicio directamente).

### Odoo
- **Versión:** Odoo 19, edición Community.
- **Addons custom:** repo git propio y separado (ya existe). Se integra al repo de infra como git submodule; el Dockerfile clona/copia ese submódulo en build time → imagen inmutable versionada por commit.
- **Addons OCA/Enterprise:** ninguno por ahora, pero la estructura de carpetas (`addons/`) y el mecanismo de submódulos quedan preparados para agregar repos OCA y el repo de Odoo Enterprise (requiere acceso con licencia) sin rediseñar nada.
- **Orden de `addons_path`** (referencia oec.sh `/guides/odoo-enterprise-vs-community-docker`, `/guides/oca-modules-guide`): `enterprise-addons` **primero** (los módulos Enterprise sobreescriben por nombre a su equivalente Community), después `custom-addons` (propios), después `oca-addons`, y al final los `extra-addons`/core de la imagen oficial.
- **Si se activa Enterprise:** requiere suscripción válida (sin ella los módulos no cargan, no hay error duro); la licencia cubre dev/staging/testing además de prod. Sumar al Dockerfile las dependencias Python que usan varios módulos Enterprise: `python-stdnum vobject xlrd num2words phonenumbers python-barcode qrcode cryptography`.
- **OCA:** cada repo como submódulo git separado, pineado a un tag/commit específico de la versión de Odoo (no a la rama, para reproducibilidad). Repos más comunes si hacen falta: `server-tools`, `web`, `partner-contact`, `account-financial-tools`, `sale-workflow`, `stock-logistics-warehouse`. Antes de instalar un módulo OCA nuevo, chequear que no duplique algo que ya cubre Enterprise (si se llega a activar).

### PostgreSQL
- **Despliegue:** contenedor Docker dedicado (imagen oficial `postgres`), uno por entorno (prod y staging con sus propios contenedor + volumen persistente, sin compartir instancia).
- **Connection pooling:** PgBouncer delante de cada Postgres, modo `transaction pooling`.

### Servidor (serverdipleg)
- CPU: AMD Ryzen 5 5600G — 6 cores / 12 threads.
- RAM: 14 GiB.
- Disco: NVMe, 879 GiB total (~597 GiB libres).

### Sizing (adaptado de oec.sh — conservador en RAM, ya que RAM es el cuello de botella real al compartir servidor entre 2 entornos)
Referencia oec.sh (`/guides/odoo-performance`), asumiendo servidor dedicado: `workers=(cores×2)+1`, `limit_memory_soft=2GiB`, `limit_memory_hard=2.5GiB`, `shared_buffers=25% RAM`, `work_mem=64MB`, `effective_cache_size=50-75% RAM`, `max_connections=100`, `random_page_cost=1.1` (SSD), PgBouncer `pool_mode=transaction`, `default_pool_size=20`, `max_client_conn=200`.

Adaptado para este servidor (12 threads / 6 cores físicos, 14 GiB RAM, compartido prod+staging):

| | Odoo workers HTTP | `max_cron_threads` | `limit_memory_soft` | `limit_memory_hard` | Postgres `shared_buffers` |
|---|---|---|---|---|---|
| **Prod** | 3 | 2 | 1638 MiB | 2048 MiB | 1.5 GiB |
| **Staging** | 1 | 1 | 546 MiB | 682 MiB | 512 MiB |

(Valores finales, revisados tras el análisis de RAM con staging efímera — ver "Presupuesto de RAM". Staging queda a 1 worker porque es de uso individual y puntual, no concurrente. Prod sube su techo de memoria por worker respecto al primer borrador conservador, sin tocar el conteo de workers; se mantiene la proporción soft/hard de oec.sh (80%) en ambos entornos.)

Postgres común a ambos: `work_mem=64MB`, `random_page_cost=1.1` (NVMe), `max_connections=100` (real, protegido por PgBouncer). PgBouncer: `pool_mode=transaction`, `default_pool_size=20`, `max_client_conn=200`, `listen_port=6432`.

Reserva ~2-3 GiB para SO + Docker + Traefik + cloudflared + PgBouncer + monitoring. Ajustar límites de memoria hacia arriba si se observan recycles de workers frecuentes en prod una vez en operación real.

### Backups (referencia oec.sh — `/guides/odoo-backup-recovery`)
- Backup completo = `pg_dump -Fc` (DB) + filestore (`tar/gzip`) — ambos son obligatorios, uno sin el otro deja el restore incompleto.
- Frecuencia mínima recomendada: diaria (cada 4-6h si hay alto volumen transaccional — no aplica por ahora, volumen bajo).
- Cifrado obligatorio antes de subir a la nube: GPG AES-256 u OpenSSL.
- Sync a storage remoto vía `rclone`.
- **Storage remoto:** Cloudflare R2 (cero egress, mismo ecosistema que el Tunnel). Subida vía `rclone` con endpoint `https://<account-id>.r2.cloudflarestorage.com`, storage class Standard-IA (acceso infrecuente, más barato) para respaldos que no son el más reciente.
- **Copia local:** últimos 7 días en disco del servidor (restore rápido sin depender de internet, disco es el recurso limitado acá) — no tiene que coincidir con la retención de R2.
- **Retención GFS en R2** (oec.sh tal cual — sin adaptar; R2 es barato/sin egress, no hay motivo de costo para acortarla, y guardar más granularidad diaria da mejor punto de recuperación ante un problema detectado tarde):
  - Diarios: 30 días.
  - Semanales: 3 meses.
  - Mensuales: 1 año, en Standard-IA.
  - R2 no tiene tiers Glacier/Deep Archive (solo Standard y Standard-IA) — si se necesita retención >1 año, exportar manualmente a almacenamiento frío aparte.
- **Restore de prueba:** no requiere cron propio — cada arranque de staging efímera (`make staging-up` / `up-staging`) ya restaura el último backup como parte de su flujo normal (ver "Refresh de staging"), lo cual cumple (y supera en frecuencia) la recomendación de oec.sh de probar restores mensualmente.
- **Ejecución:** contenedor efímero dedicado, no script en el host — ver "Contenedor de backup" más abajo.

### Contenedor de backup
- `docker-compose.backup.yml` — 5to stack, un solo servicio (`backup`), efímero: no queda corriendo, se invoca y termina.
- Imagen propia: `FROM postgres:19-alpine` (mismo binario `pg_dump` que la versión de Postgres en uso) + `rclone` + `gnupg`.
- Se conecta a `db` por la red interna de Docker (mismo mecanismo que el resto — sin publicar puertos), y monta el volumen de filestore de Odoo **read-only** para el `tar`.
- Disparo: systemd timer diario → `docker compose -f docker-compose.backup.yml run --rm backup` (equivalente al target `prod-backup-run` del Makefile). Costo de RAM ≈ 0 fuera de la ventana en que corre (minutos), no un daemon permanente.

### Monitoring
- **Stack:** Prometheus + Grafana (elegido sobre la alternativa liviana Uptime Kuma). Ver "Presupuesto de RAM" más abajo — con staging efímera el margen es cómodo, ya no hace falta recortar este stack por RAM.
- **Exporters:** node-exporter (host), cAdvisor (por contenedor), postgres_exporter (DB). Sin exporter de Odoo (no existe uno oficial mantenido) — si hace falta más adelante, healthcheck HTTP simple en su lugar.
- **Alertas:** Grafana Alerting (sin Alertmanager separado) → Telegram/email. Dispara con: RAM del host por encima de umbral, contenedor caído, Postgres sin conexiones disponibles.
- **Logs centralizados:** Loki + Promtail (integrado a Grafana).

### Presupuesto de RAM (estimado, 14 GiB totales) — final, tras staging efímera + ajuste de memory limits
Dos escenarios (staging efímera: apagada la mayor parte del tiempo, activa solo en ventanas de 3h — ver "Refresh de staging"):

| Componente | Baseline (staging apagada) | Peak (staging activa, ventana de 3h) |
|---|---|---|
| Odoo prod (3 workers, `hard=2048 MiB` + overhead) | ~6.5 GiB | ~6.5 GiB |
| Postgres prod (`shared_buffers` 1.5 GiB + overhead) | ~2.0 GiB | ~2.0 GiB |
| PgBouncer prod, Traefik, cloudflared | ~0.2 GiB | ~0.2 GiB |
| Prometheus + Grafana + cAdvisor + node-exporter + postgres-exporter-prod | ~0.9 GiB | ~0.9 GiB |
| Loki + Promtail | ~0.4 GiB | ~0.4 GiB |
| Runner GitHub Actions + SO | ~1.0 GiB | ~1.0 GiB |
| Odoo staging (1 worker, `hard=682 MiB` + overhead) | — | ~1.17 GiB |
| Postgres staging (`shared_buffers` 512 MiB + overhead) | — | ~0.8 GiB |
| PgBouncer staging, postgres-exporter-staging | — | ~0.15 GiB |
| **Total estimado (peor caso)** | **~11.0 GiB** | **~13.1 GiB** |

**Margen real: ~3.0 GiB en baseline (la mayor parte del tiempo), ~0.9 GiB en peak** (staging activa + los 3 workers de prod tocando su techo simultáneamente — escenario poco frecuente, ya que staging es de uso individual y puntual). Sumado a los 4 GiB de swap del servidor como colchón adicional ante ese peor caso puntual. `postgres-exporter-staging` conviene definirlo en `docker-compose.staging.yml` (no en el stack de monitoring permanente), así arranca y muere junto con staging en vez de quedar como target de Prometheus fallando cuando staging está abajo.

**Contenedor de backup (efímero, `mem_limit: 1g`):** no figura como línea fija en la tabla porque corre solo unos minutos por día (systemd timer diario, medianoche) y su costo de RAM es ≈0 fuera de esa ventana. La feature `004-backup-restic` subió su techo de 512m a 1g (restic mantiene índice en memoria y `prune` lo reconstruye). Reconciliación contra el presupuesto: en **baseline** (staging apagada, el caso normal a medianoche) hay ~3.0 GiB de margen, así que 1g entra holgado. El único borde ajustado es el **solape backup×staging** (alguien con staging levantada justo a medianoche): peak ~13.1 GiB + 1.0 GiB = ~14.1 GiB, apenas sobre los 14 GiB físicos — absorbido por los 4 GiB de swap, y de todas formas improbable (staging es on-demand y puntual, el timer corre a una hora de baja actividad). No se toma ninguna acción de sizing extra; si en operación real se observa presión de memoria en ese solape, la palanca es mover el `OnCalendar` del timer a una hora donde staging nunca esté activa.

### Deploy de actualizaciones de módulos
- Update selectivo automatizado: el pipeline detecta qué carpetas de `addons/` cambiaron desde el último deploy y corre `odoo -u <módulos_modificados> --stop-after-init` antes de reiniciar los workers. Sin `-u all` (más lento y arriesgado en prod real).

### Dominios
- **Prod:** `odoo.miempresa.com`
- **Staging:** `staging.miempresa.com`
- Ambos como hostnames dentro del mismo Cloudflare Tunnel, enrutados por Traefik al contenedor correspondiente.

### Refresh de staging (referencia oec.sh — `/guides/odoo-staging`)
- Sin cadencia programada — staging es efímera (levanta on-demand, hasta 3h, ver "Sizing"/Makefile), así que cada arranque restaura el último backup de prod. No hace falta un refresh "semanal" separado: el uso normal de staging ya la mantiene siempre al día, y de paso cumple el rol del restore de prueba que recomienda oec.sh.
- ⚠️ **Orden crítico:** el script de anonimización corre inmediatamente después de restaurar la base y **antes** de levantar el contenedor Odoo — si Odoo arranca primero con datos de prod sin anonimizar, los cron de mail encolados pueden disparar emails reales a clientes.
- SQL de anonimización: `UPDATE ir_mail_server SET active = false` (corta servidores de saliente), passwords de usuarios reseteados a valores random, `UPDATE res_partner SET email = 'staging+' || id || '@example.com'`, deshabilitar payment providers y limpiar URLs de webhooks en `ir_config_parameter`, desactivar crons relacionados a mail.
- Config propia de staging en `odoo.conf`: solo `db_name` distinto (`odoo_staging`). Sin `dev_mode` — staging corre con el mismo modelo multiproceso que prod (workers, sin hot-reload), para que sea una réplica fiel a menor escala y no un modo de ejecución distinto (ver "Sizing": 1 worker, sin `dev_mode`, mismo ruteo de longpolling que prod). oec.sh también sugiere puerto HTTP distinto, pero no aplica acá — cada entorno es un contenedor separado con su propio namespace de red, así que ambos pueden usar 8069 internamente sin conflicto; Traefik distingue por hostname, no por puerto.

### Seguridad del host — principio de diseño (independiente de cualquier infra previa)
- **Ningún contenedor publica puertos al host** (sin `ports:` en `docker-compose.yml` para Odoo/Postgres/PgBouncer/Traefik). Todo vive en una red interna de Docker.
- `cloudflared` corre como contenedor en esa misma red interna y le habla a Traefik por DNS interno de Docker (`http://traefik:80`), no por `localhost`/puerto de host.
- Con esto, nada queda expuesto al host ni a internet salvo a través del Tunnel — independientemente de la configuración de `ufw`/reglas de Docker en el servidor.

### Imagen Docker
- `Dockerfile` propio `FROM odoo:19.0` (referencia oec.sh `/guides/odoo-docker-hub`: usar el tag de versión mayor `X.0`, nunca `latest` — ese tag salta de versión mayor automáticamente y puede romper compatibilidad con la base ya migrada). Build copia `addons/` (submódulos custom + OCA), instala requirements Python adicionales si algún módulo los necesita (`find addons -name requirements.txt -exec pip install -r {} \;`), y fija `entrypoint` para aceptar el `-u <módulos>` selectivo del deploy.
- **Tag fijo por build** (commit SHA), además del tag base `19.0` — cada deploy queda atado a una imagen reproducible.
- **Nunca `user: root`** — la imagen oficial ya corre como `odoo` (UID 101).
- Updates de parche dentro de la misma versión mayor (`docker compose pull && up -d`) son seguros — Odoo aplica cambios de schema menores solo al arrancar. Upgrades de versión mayor (19→20) requieren proceso formal de migración, no es solo cambiar el tag.

### Buenas prácticas de contenedor (oec.sh — `/guides/odoo-docker-compose`, `/guides/odoo-docker`)
- **Healthchecks:**
  - Odoo: `curl -f http://localhost:8069/web/health` — interval 30s, timeout 10s, retries 3, start period 60s.
  - Postgres: `pg_isready -U ${POSTGRES_USER}` — interval 10s, timeout 5s, retries 5, start period 30s.
  - Odoo usa `depends_on: db: condition: service_healthy` (no arranca hasta que Postgres esté listo).
- **`restart: unless-stopped`** en todos los contenedores.
- **Volúmenes con nombre** (no bind mounts) para filestore (`/var/lib/odoo`) y datos de Postgres. ⚠️ `PGDATA` debe apuntar a un *subdirectorio* del volumen (`/var/lib/postgresql/data/pgdata`), no al mount point directo — evita conflictos de metadata de Docker.
- `odoo.conf` montado **read-only** (`:ro`).
- **Variables de entorno de Odoo** limitadas a `HOST/PORT/USER/PASSWORD` (conexión a DB); todo lo demás (`workers`, `list_db`, `proxy_mode`, `addons_path`, `max_cron_threads`) va en `odoo.conf`.
- **`list_db = False`** en `odoo.conf` — deshabilita el database manager web (`/web/database/manager`), evita que se pueda crear/listar/borrar la base desde el navegador. No negociable en prod.
- **`proxy_mode = True`** en `odoo.conf` (necesario detrás de Traefik, para headers `X-Forwarded-*` correctos).
- **Log rotation:** driver `json-file`, `max-size: 50m`, `max-file: 5`.
- **Límites de recursos también a nivel Docker Compose** (además de `limit_memory_soft/hard` de Odoo, que son a nivel proceso): `mem_limit`/`mem_reservation` y `cpus` por contenedor, como segunda capa de protección para que ningún contenedor se coma toda la RAM del host compartido.

### Longpolling / websocket (chat y notificaciones en tiempo real)
- Odoo separa tráfico HTTP normal (puerto **8069**) de websocket/gevent (puerto **8072**).
- Traefik define **dos routers** por instancia: uno para `/websocket` → puerto 8072 (con headers `Upgrade`/`Connection: upgrade`), otro para el resto del tráfico → puerto 8069.

### SSL / dominios (nota de desvío respecto a oec.sh)
- La guía de oec.sh (`/guides/ssl-custom-domains`) asume Nginx + Let's Encrypt/certbot con renovación automática y DNS tipo A/AAAA apuntando a una IP pública. **No aplica tal cual acá**: con Cloudflare Tunnel, TLS se termina en el edge de Cloudflare — no hay certificado que gestionar ni renovar en el servidor. El tráfico `cloudflared → Traefik` es HTTP plano dentro de la red interna de Docker (no cruza internet).
- Equivalentes de config que sí aplican, trasladados a Traefik: `client_max_body_size 200m` (adjuntos grandes) → límite de tamaño de request en Traefik/middleware; `proxy_read_timeout 900s` (reportes/operaciones largas) → timeout de respuesta configurado en el router de Traefik.

### CI/CD (referencia oec.sh — `/guides/odoo-cicd-staging`)
- **Repos:** GitHub (infra + addons custom).
- **Pipeline:** Commit → Lint → Tests → Build → Deploy Staging → QA → Deploy Prod (manual).
  - **Lint:** `pylint-odoo` + `flake8` + `black --check` + `isort --check` sobre el repo de addons custom.
  - **Tests:** suite existente de los módulos custom, vía `odoo-bin -d test_db --test-enable --stop-after-init`.
  - **Deploy staging:** automático en push/merge a `staging` (branch equivalente a `develop`), tras pasar lint+tests.
  - **Deploy prod:** manual, disparado desde `main`/`production`, después de validación en staging. Nunca automático.
- **Approval gates:** 1 aprobación para mergear a `staging`, 2 aprobaciones para mergear a `main`. Checks de lint+tests deben pasar antes de poder mergear.
- **Rollback:** revertir al commit anterior (`git checkout`/revert) y re-deployar esa imagen ya buildeada (tag por commit SHA, ver Imagen Docker); restore de DB desde el backup pre-deploy solo si el problema incluyó una migración de datos, no en cada rollback.
- **Runner:** self-hosted GitHub Actions runner instalado en el propio servidor (polling saliente hacia GitHub, sin puertos entrantes ni SSH remoto — coherente con el modelo Cloudflare Tunnel). El runner ejecuta `docker compose pull/up` con acceso directo al Docker daemon local.
- Deploys a prod fuera de horario pico, con backup pre-deploy tomado automáticamente por el pipeline antes de aplicar el `-u <módulos>`.

### Secrets
- **Build/deploy (pipeline):** GitHub Actions Secrets.
- **Runtime (contenedores):** `.env` por entorno en el servidor, fuera del repo (`chmod 600`, `.gitignore`), referenciado vía `env_file` en `docker-compose.yml`.

### Makefile — interfaz operativa (local y CI comparten los mismos targets)
Targets explícitos, con convención de nombre **`<stack>-<service>-<action>`** (nada de variables que memorizar; tab-completion muestra todo el universo de comandos).

5 stacks de Compose, cada uno con sus servicios:

| stack | archivo | servicios |
|---|---|---|
| `prod` | `docker-compose.prod.yml` | `odoo`, `db`, `pgbouncer` |
| `staging` | `docker-compose.staging.yml` | `odoo`, `db`, `pgbouncer`, `postgres-exporter` (nace/muere con staging, no vive en `monitoring`) |
| `edge` | `docker-compose.edge.yml` | `traefik`, `cloudflared` |
| `monitoring` | `docker-compose.monitoring.yml` | `prometheus`, `grafana`, `loki`, `promtail`, `cadvisor`, `node-exporter`, `postgres-exporter-prod` |
| `backup` | `docker-compose.backup.yml` | `backup` (servicio único, efímero — ver "Contenedor de backup") |

Acciones por servicio: `up`, `stop`, `restart`, `logs` (todos) · `rebuild` (solo `odoo`, único con build propio) · `pull` (solo servicios de imagen oficial) · `restore` (solo `db`, restaura DB+filestore juntos) · `run` (solo `backup`, contenedor efímero: `run --rm` en vez de `up -d`).

Ejemplos:

```makefile
prod-odoo-up:            ; $(COMPOSE_PROD) up -d odoo
prod-odoo-rebuild:       ; $(COMPOSE_PROD) build --no-cache odoo && $(COMPOSE_PROD) up -d odoo
prod-db-restore:         ; ./scripts/restore.sh prod $(CONFIRM)   # ⚠️ exige CONFIRM=yes, disaster recovery únicamente

staging-db-restore:      ; ./scripts/restore.sh staging   # uso frecuente, sin CONFIRM
staging-odoo-logs:       ; $(COMPOSE_STAGING) logs -f odoo

edge-traefik-restart:    ; $(COMPOSE_EDGE) restart traefik

monitoring-grafana-up:   ; $(COMPOSE_MONITORING) up -d grafana

backup-backup-run:       ; $(COMPOSE_BACKUP) run --rm backup   # disparado también por systemd timer diario
```

Más targets compuestos a nivel stack completo (`prod-up`, `staging-down`, `deploy-prod`, `up-staging` con restore+timer de 3h, `extend-staging`, `backup`, `status`), siguiendo los flujos ya documentados en el resto del documento. El patrón se repite igual para cada combinación stack×servicio×acción de la tabla de arriba — no hace falta enumerarlas todas acá.

⚠️ `prod-db-restore` es destructivo sobre datos reales — el script exige `CONFIRM=yes` explícito además del target, para que no sea invocable por error.

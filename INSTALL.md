# Instalación

A partir de la feature `008-makefile`, el `Makefile` en la raíz es la interfaz operativa única — cada comando `docker`/`docker compose` de este documento tiene un target `make` equivalente (`make help` lista todos). Los comandos directos siguen documentados acá porque son lo que el target ejecuta por dentro; usar uno u otro da el mismo resultado.

Desde la feature `013-stack-layout-reorg`, cada stack vive autocontenido en su propia carpeta de primer nivel (`prod/`, `staging/`, `edge/`, `monitoring/`, `backup/`), cada una con `docker/`, `config/` y `env/` adentro — `prod` y `staging` tienen su propia imagen de Odoo independiente (`Dockerfile`), nunca compartida.

## Prerrequisitos

- **Docker Engine + Docker Compose plugin** ya instalados en el server (`docker compose version` debe funcionar). Este documento no cubre esa instalación — depende de la distro del server.
- **Cuenta de Cloudflare con un dominio ya delegado ahí** (DNS del dominio administrado por Cloudflare, zona activa) — se necesita antes de llegar al paso 3, para crear el Tunnel y las rutas.

Secuencia completa, de punta a punta. El orden está forzado por dependencias reales, no es arbitrario: `edge` va antes que `backup`/`staging`/`monitoring` porque los tres cuelgan una ruta del mismo Tunnel creado ahí; `backup` va antes que `staging` porque el restore de staging lee del repo local que `backup` puebla:

0. Clonar el repo, pineado a un release (tag)
1. Red, volúmenes e imágenes propias (bootstrap, una sola vez)
2. Stack `prod`
3. Stack `edge` (Traefik + Cloudflare Tunnel)
4. Stack `backup` (Postgres RO + restic → local + R2)
5. Stack `staging` siempre-arriba (restore + anonimización, refresh semanal)
6. Stack `monitoring` (Prometheus + Grafana + Loki + exporters)
7. Restore de prod (disaster recovery)
8. Desarme (solo si esto fue una prueba, no un despliegue definitivo)

## 0. Clonar el repo, pineado a un release (tag)

El server corre siempre un release taggeado, nunca la punta de `main` — así el deploy es reproducible y no arrastra commits posteriores sin querer:

```bash
git clone <url-del-repo> /opt/odoo-infrastructure
cd /opt/odoo-infrastructure
git fetch --tags
git checkout vX.Y.Z   # el tag del release a instalar
```

Esto deja el repo en **detached HEAD** apuntando exactamente al commit del tag — es lo esperado (git va a avisar), no se commitea nada ahí.

Para actualizar a un release posterior:

```bash
git fetch --tags
git checkout vX.Y.Z
```

**Siempre rebuildear después de cambiar de tag.** `docker compose up -d` nunca reconstruye una imagen por sí solo — si el `Dockerfile` cambió entre releases pero la imagen local (`odoo-prod:<tag-viejo>`) ya existe con ese nombre, sigue usando la vieja hasta que se la reconstruya explícitamente con el `TAG` nuevo. Repetir el build (paso 1) y confirmar que el `CMD`/`ENTRYPOINT` quedaron como espera el `Dockerfile` actual, antes de asumir que el problema es otra cosa:

```bash
export TAG=$(git rev-parse --short HEAD)
docker compose -f prod/docker/docker-compose.yml build --no-cache odoo
docker inspect --format 'ENTRYPOINT={{.Config.Entrypoint}} CMD={{.Config.Cmd}}' odoo-prod:$TAG
docker compose -f prod/docker/docker-compose.yml up -d odoo
```

## 1. Red, volúmenes e imágenes propias (bootstrap, una sola vez)

### 1.1 Red y volumen

`prod` y `edge` se conectan por una red Docker externa compartida (`prod-net`, también usada por `monitoring`), `prod`/`backup` comparten el volumen del filestore de Odoo, y `staging` vive en su propia red aislada (Traefik es el único que se une a ambas):

```bash
docker network create prod-net
docker network create staging-net
docker volume create odoo-data-prod
```

### 1.2 Build de las imágenes de Odoo (prod y staging)

Los compose de `prod` y `staging` referencian su imagen por nombre + tag de commit (`odoo-prod:${TAG}` / `odoo-staging:${TAG}`, nunca un tag flotante) — el build de acá abajo **es** la imagen que corre en los pasos siguientes, no una aparte. `TAG` queda exportado en esta sesión de shell; todo comando de `docker compose` de los pasos siguientes lo necesita para resolver la misma imagen — si abrís una terminal nueva, volvé a exportarlo primero (`export TAG=$(git rev-parse --short HEAD)`):

```bash
export TAG=$(git rev-parse --short HEAD)
docker compose -f prod/docker/docker-compose.yml build odoo
docker compose -f staging/docker/docker-compose.yml build odoo-staging
```

Verificar que ambas quedaron etiquetadas por commit y corren como `odoo` (no root):

```bash
docker inspect --format '{{.Config.User}}' odoo-prod:$TAG      # → odoo
docker inspect --format '{{.Config.User}}' odoo-staging:$TAG   # → odoo
```

## 2. Stack de producción

### 2.1 Configuración inicial

```bash
cp prod/env/.env.prod.example prod/env/.env.prod   # completar con credenciales reales, nunca commitear
cp prod/config/odoo.conf.example prod/config/odoo.conf   # ambos gitignored, editar a mano en el server
```

### 2.2 Levantar el stack

Un solo `up -d` orquesta los 3 servicios en orden (`db` → `pgbouncer` → `odoo`, encadenados por `depends_on: condition: service_healthy` dentro del compose) — no hace falta levantarlos por separado:

```bash
docker compose -f prod/docker/docker-compose.yml up -d
```

### 2.3 Inicializar Odoo (primera vez, base vacía)

```bash
docker compose -f prod/docker/docker-compose.yml run --rm odoo odoo -d odoo -i base --stop-after-init
docker compose -f prod/docker/docker-compose.yml restart odoo
```

### 2.4 Chequear estado

```bash
docker compose -f prod/docker/docker-compose.yml ps   # confirmar que los 3 servicios están healthy
```

## 3. Stack `edge` (Traefik + Cloudflare Tunnel)

### 3.1 Configuración inicial

Crear el Tunnel en el dashboard de Cloudflare — **Networking → Tunnels → Create a tunnel**:

1. Elegir el conector `Docker` y ponerle un nombre.
2. Copiar el comando de instalación que se muestra — el token va incluido ahí (empieza con `eyJ...`), es el mismo valor que `TUNNEL_TOKEN`.
3. Ir a la pestaña **Routes** del tunnel recién creado → **Add route → Published application**.
4. Completar **Subdomain** + **Domain** (el hostname público que vas a usar) y dejar **Path** vacío.
5. En **Service URL**, escribir `http://traefik:80` (un solo campo, protocolo incluido — no hay campos separados de tipo/puerto).
6. Anotar el hostname completo resultante (ej. `odoo.tudominio.com`) — tiene que coincidir exactamente con `edge/config/traefik-dynamic.yml`.

Igualar ese hostname en la config de Traefik:

```bash
sed -i "s/odoo.miempresa.com/<tu-hostname-real>/g" edge/config/traefik-dynamic.yml
```

```bash
cp edge/env/.env.edge.example edge/env/.env.edge
# En edge/env/.env.edge: TUNNEL_TOKEN=<el token del paso anterior>
```

### 3.2 Levantar el stack

```bash
docker compose -f edge/docker/docker-compose.yml up -d
```

### 3.3 Chequear estado

```bash
docker compose -f edge/docker/docker-compose.yml ps   # traefik y cloudflared, ambos healthy
docker compose -f edge/docker/docker-compose.yml logs cloudflared --tail 20   # confirmar "Registered tunnel connection", sin errores de token
```

Verificar **desde afuera del servidor** (tu laptop, no el servidor mismo — para probar el camino completo por internet, no solo la red interna):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://<tu-hostname-real>/web/health
```

Debería dar `200` (esperar 1-2 minutos si da error de TLS/DNS recién creado el Tunnel).

## 4. Stack `backup` (Postgres RO + restic → local + R2)

`restic` provee el cifrado en reposo, la deduplicación y la retención GFS — no hay paso manual de GPG ni lógica de calendario. Cada corrida hace un snapshot (DB + filestore juntos) en el repo local y lo copia al repo R2.

### 4.1 Configuración inicial

Crear el bucket y las credenciales en el dashboard de Cloudflare — **Storage & databases → R2 → Overview**:

1. **Create bucket** → nombre del bucket, elegir location y storage class por defecto.
2. En la misma pantalla de R2 Overview, sección **API Tokens** → **Manage** → **Create Account API token** (o **User API token**).
3. Permisos: **Object Read & Write**. Alcance: **Apply to specific buckets only**, seleccionando el bucket recién creado.
4. **Create API Token** → copiar `Access Key ID` y `Secret Access Key` de inmediato (no se pueden volver a ver después).
5. Anotar el **endpoint** (`https://<account-id>.r2.cloudflarestorage.com`) — aparece en la misma pantalla de confirmación y en R2 Overview.

Crear (una sola vez) el rol de Postgres de solo lectura:

```bash
export BACKUP_DB_PASSWORD=elegir-un-password   # el mismo valor que va después en backup/env/.env.backup
./scripts/setup-backup-role.sh   # lee POSTGRES_USER de prod/env/.env.prod automáticamente; seguro de re-correr
```

Preparar la carpeta de los repos y la config:

```bash
sudo mkdir -p /srv/odoo-backups
sudo mkdir -p /srv/node-exporter-textfile   # métrica de freshness, leída por node-exporter (stack monitoring)
cp backup/env/.env.backup.example backup/env/.env.backup
```

Completar `backup/env/.env.backup` con los datos del bucket recién creado:

```bash
PGPASSWORD=<mismo valor que BACKUP_DB_PASSWORD>
RESTIC_PASSWORD=elegir-una-passphrase          # guardarla fuera del server: sin ella los backups son irrecuperables
RESTIC_REPOSITORY_LOCAL=/backups/restic
RESTIC_REPOSITORY_R2=s3:https://<account-id>.r2.cloudflarestorage.com/<nombre-del-bucket>
AWS_ACCESS_KEY_ID=<Access Key ID>
AWS_SECRET_ACCESS_KEY=<Secret Access Key>
```

### 4.2 Levantar el stack

Queda siempre arriba, `restart: unless-stopped` — expone un healthcheck que confirma si el último backup exitoso está fresco (ver 4.5):

```bash
docker compose -f backup/docker/docker-compose.yml up -d backup
```

### 4.3 Primer backup

Correr el primer backup dentro del contenedor ya levantado (la primera corrida hace `restic init` de ambos repos automáticamente — el timer diario usará este mismo comando). **Este backup tiene que terminar OK antes de seguir al paso 5** — `staging` restaura del repo local que esta corrida puebla:

```bash
docker compose -f backup/docker/docker-compose.yml exec -T backup /usr/local/bin/backup.sh
```

Confirmar el snapshot en ambos repos:

```bash
docker compose -f backup/docker/docker-compose.yml run --rm --entrypoint restic backup -r /backups/restic snapshots
# R2: mismo comando con -r "$RESTIC_REPOSITORY_R2" (requiere las AWS_* del backup/env/.env.backup)
```

**Verificar el round-trip de restore** (confirma que el backup es genuinamente recuperable, no solo que el snapshot existe):

```bash
docker compose -f backup/docker/docker-compose.yml run --rm --entrypoint restic backup \
  -r /backups/restic restore latest --target /backups/restore-test
# El dump plano queda en /srv/odoo-backups/restore-test/.../db.sql →
# cargarlo en una DB vacía con psql confirma que la DB es recuperable;
# el directorio del filestore recuperado confirma el otro medio backup.
sudo rm -rf /srv/odoo-backups/restore-test
```

> **Migración desde el backup viejo (feature 003):** al reemplazar el script, la poda GFS en bash desaparece, así que los `.gpg` viejos (locales en `/srv/odoo-backups` y prefijos `daily/weekly/monthly` en R2) **ya no se podan solos**. Tras ≥14 días corriendo restic sin problemas (cubre la retención diaria), borrarlos a mano una única vez: `sudo rm -f /srv/odoo-backups/*.gpg` y eliminar los prefijos `daily/`, `weekly/`, `monthly/` del bucket en el dashboard de R2.

### 4.4 Timer diario

```bash
sudo cp systemd/odoo-backup.service systemd/odoo-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now odoo-backup.timer
systemd-analyze verify systemd/odoo-backup.service systemd/odoo-backup.timer
```

### 4.5 Chequear estado

El contenedor expone un `HEALTHCHECK` que confirma si el último backup exitoso tiene menos de ~26h — visible en `docker compose -f backup/docker/docker-compose.yml ps` (`healthy`/`unhealthy`) y en `docker inspect --format '{{.State.Health.Status}}' <container>`. Si el timer alguna vez deja de correr o `backup.sh` empieza a fallar, el contenedor pasa a `unhealthy` sin necesidad de leer logs a mano. (cAdvisor no expone el estado de `HEALTHCHECK` de Docker como métrica — solo recursos vía cgroups — así que esto **no** es visible como tal en Prometheus/Grafana hoy; ver backlog para llevar esta señal a una métrica real.)

## 5. Stack `staging` siempre-arriba (restore + anonimización, refresh semanal)

Réplica de prod a menor escala (mismo modelo multiproceso, sin `dev_mode`, mismos datos reales anonimizados — pero corre su propia imagen, con `Dockerfile` independiente del de prod), en su propia red aislada — no comparte `prod-net` con prod. Se levanta una vez y queda arriba de forma permanente (`restart: unless-stopped`, sobrevive un reinicio del server); se refresca solo una vez por semana (systemd timer → mismo ciclo restore + anonimización de siempre, **antes** de arrancar Odoo). Pausar sin perder los datos del último refresh es `docker compose -f staging/docker/docker-compose.yml stop`; bajarla del todo (destructivo) es `nuke-staging.sh` (o `make nuke-staging`).

**Requiere que el paso 4 ya haya corrido con éxito** — el restore de acá abajo lee del repo restic **local** (`/srv/odoo-backups`) que ese paso pobló; sin un backup exitoso previo, el restore no tiene de dónde traer datos.

### 5.1 Configuración inicial

Agregar la segunda ruta al mismo Tunnel de Cloudflare creado en el paso 3 — dashboard → el mismo tunnel → **Routes → Add route → Published application**:

1. **Subdomain** `staging`, mismo **Domain** que prod, **Path** vacío.
2. **Service URL**: `http://traefik:80` (igual que prod — Traefik distingue por `Host`, no por Tunnel).

Igualar el hostname en la config de Traefik, y reiniciar Traefik para que la tome — el `file provider` de Traefik lee el archivo **una sola vez al arrancar**, no lo vuelve a mirar solo:

```bash
sed -i "s/staging.miempresa.com/staging.<tu-dominio-real>/g" edge/config/traefik-dynamic.yml
docker compose -f edge/docker/docker-compose.yml restart traefik
```

Completar credenciales:

```bash
cp staging/env/.env.staging.example staging/env/.env.staging   # completar con credenciales reales, nunca commitear
cp staging/config/odoo-staging.conf.example staging/config/odoo-staging.conf   # ambos gitignored, editar a mano en el server
```

La imagen de `staging` ya se buildeó en el paso 1.2 — si es una terminal nueva, `TAG` no está exportado ahí; volvé a exportarlo antes de seguir (`export TAG=$(git rev-parse --short HEAD)`).

### 5.2 Levantar el stack

`refresh-staging.sh` hace todo el ciclo en el orden crítico automático (restore → anonimización → recién Odoo):

```bash
./scripts/refresh-staging.sh
```

### 5.3 Chequear estado

```bash
docker compose -f staging/docker/docker-compose.yml ps   # los 4 servicios healthy
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://staging.<tu-dominio-real>/web/health   # 200
```

**Verificar la anonimización** (confirma que ningún dato real de cliente quedó expuesto):

```bash
docker compose -f staging/docker/docker-compose.yml exec -T db psql -U "$POSTGRES_USER" -d odoo_staging \
  -c "SELECT count(*) FROM ir_mail_server WHERE active;"   # → 0
```

Pedir un ciclo nuevo a mano en cualquier momento (`refresh-staging.sh` hace teardown + fresh restore si staging ya está activa), o bajarla del todo si hace falta liberar el ambiente:

```bash
./scripts/refresh-staging.sh   # refresh manual, mismo ciclo que el timer semanal — o: make refresh-staging
./scripts/nuke-staging.sh      # baja y destruye volúmenes (down -v) — deliberado, no automático — o: make nuke-staging
```

### 5.4 Timer de refresh semanal

```bash
sudo cp systemd/staging-refresh.service systemd/staging-refresh.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now staging-refresh.timer
systemd-analyze verify systemd/staging-refresh.service systemd/staging-refresh.timer
```

No hace falta instalar nada para que staging vuelva sola tras un reinicio del server — `restart: unless-stopped` en los 4 servicios ya lo cubre, mismo mecanismo que `prod`/`edge`/`backup`.

**Promover un cambio validado en staging hacia prod** (ej. una dependencia nueva agregada en `staging/docker/Dockerfile`, un addon, un bump de versión de Odoo): es un cambio de código explícito, nunca automático — editar `prod/docker/Dockerfile` a mano para reflejar el cambio validado, en un commit/PR revisado como cualquier otro cambio de infra, y recién ahí `rebuild-prod-odoo`.

> **Migración desde un deploy con el teardown de boot viejo (feature 005):** si `staging-teardown-boot.service` ya estaba instalado y habilitado, hay que deshabilitarlo explícitamente antes de actualizar — si no, sigue destruyendo staging en cada reinicio con el comportamiento viejo: `sudo systemctl disable --now staging-teardown-boot.service && sudo rm -f /etc/systemd/system/staging-teardown-boot.service && sudo systemctl daemon-reload`.

## 6. Stack `monitoring` (Prometheus + Grafana + Loki + exporters)

Stack siempre-arriba, en `prod-net` (sin publicar puertos). Recolecta métricas de host/contenedores/Postgres prod, centraliza logs de todos los contenedores, y expone Grafana en `grafana.miempresa.com` por el edge existente.

### 6.1 Configuración inicial

Crear (una sola vez) el rol de Postgres de solo lectura para el exporter:

```bash
export MONITORING_DB_PASSWORD=elegir-un-password   # el mismo valor que va después en monitoring/env/.env.monitoring
./scripts/setup-monitoring-role.sh   # lee POSTGRES_USER de prod/env/.env.prod automáticamente; seguro de re-correr
```

Agregar la tercera ruta al mismo Tunnel de Cloudflare creado en el paso 3 — dashboard → el mismo tunnel → **Routes → Add route → Published application**:

1. **Subdomain** `grafana`, mismo **Domain** que prod, **Path** vacío.
2. **Service URL**: `http://traefik:80` (igual que prod/staging — Traefik distingue por `Host`).

Igualar el hostname en la config de Traefik, y reiniciar Traefik para que la tome (mismo motivo que en el paso 5 — el `file provider` no recarga solo):

```bash
sed -i "s/grafana.miempresa.com/grafana.<tu-dominio-real>/g" edge/config/traefik-dynamic.yml
docker compose -f edge/docker/docker-compose.yml restart traefik
```

**Proteger `grafana.<tu-dominio-real>` con Cloudflare Access** (Access intercepta la request antes de que llegue a Grafana; el login propio de Grafana es la segunda capa) — dashboard → **Zero Trust → Access → Applications → Add an application**:

1. Tipo de aplicación: **Self-hosted**.
2. **Application domain**: el hostname `grafana.<tu-dominio-real>` recién creado.
3. En la política de acceso, agregar una regla **Include** con tu email (o el dominio de email del equipo) — solo esa identidad puede pasar.
4. Método de login: **One-time PIN** (por email) alcanza para un operador único; no requiere IdP externo.
5. Guardar — a partir de acá, cualquier visita a `grafana.<tu-dominio-real>` pide autenticación de Cloudflare Access antes de mostrar el login de Grafana.

Completar credenciales:

```bash
cp monitoring/env/.env.monitoring.example monitoring/env/.env.monitoring
# GF_SERVER_ROOT_URL trae el dominio de ejemplo — reemplazarlo por el hostname real recién creado:
sed -i "s|GF_SERVER_ROOT_URL=https://grafana.miempresa.com|GF_SERVER_ROOT_URL=https://grafana.<tu-dominio-real>|" monitoring/env/.env.monitoring
```

Completar el resto a mano en `monitoring/env/.env.monitoring` (el password de `MONITORING_DB_PASSWORD` va embebido en el DSN de `DATA_SOURCE_NAME`, no como variable separada; también SMTP y `OPERATOR_EMAIL`), nunca commitear.

### 6.2 Levantar el stack

```bash
docker compose -f monitoring/docker/docker-compose.yml up -d
```

### 6.3 Chequear estado

```bash
docker compose -f monitoring/docker/docker-compose.yml ps   # los 7 servicios healthy/running
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://grafana.<tu-dominio-real>   # 200 (o el desafío de Cloudflare Access)
```

Confirmar que Prometheus tiene todos los targets arriba:

```bash
docker compose -f monitoring/docker/docker-compose.yml exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets
```

Operación diaria: `make up-monitoring` / `make down-monitoring` / `make logs-monitoring-<servicio>` (o los comandos `docker compose` de arriba, equivalentes).

## 7. Restore de prod (disaster recovery)

Restaura la DB + filestore de producción desde un backup restic — **destructivo**, sobrescribe los datos actuales de prod. Reservado para recuperación tras pérdida/corrupción real, no para uso rutinario (eso es `refresh-staging`).

Por defecto restaura desde **R2** (off-site — cubre el caso de haber perdido el server/disco entero, que es lo que justifica esta operación). Si el disco/repo local está intacto y se busca velocidad, se puede forzar con `LOCAL=yes`:

```bash
make restore-prod CONFIRM=yes            # restaura desde R2 (default)
make restore-prod CONFIRM=yes LOCAL=yes  # restaura desde el repo local (más rápido, sin red)
```

Sin `CONFIRM=yes` exacto, el comando aborta sin tocar nada — no es invocable por error. El script para `odoo`+`pgbouncer` antes de restaurar, y solo los vuelve a levantar si el restore terminó bien; si falla, prod queda parado en vez de servir datos a medias.

Equivalente directo (lo que el target ejecuta por dentro):

```bash
./scripts/prod-db-restore.sh
```

## 8. Desarme (solo si esto fue una prueba)

```bash
docker compose -f monitoring/docker/docker-compose.yml down -v
docker compose -f staging/docker/docker-compose.yml down -v
sudo systemctl disable --now staging-refresh.timer 2>/dev/null || true
sudo systemctl disable --now odoo-backup.timer 2>/dev/null || true
sudo rm -f /etc/systemd/system/odoo-backup.service /etc/systemd/system/odoo-backup.timer
sudo rm -f /etc/systemd/system/staging-refresh.service /etc/systemd/system/staging-refresh.timer
sudo systemctl daemon-reload
docker compose -f backup/docker/docker-compose.yml down
docker compose -f edge/docker/docker-compose.yml down
docker compose -f prod/docker/docker-compose.yml down -v
docker network rm prod-net staging-net
docker volume rm odoo-data-prod
export TAG=$(git rev-parse --short HEAD)
docker image rm "odoo-prod:$TAG" "odoo-staging:$TAG" odoo-infrastructure-backup-backup 2>/dev/null || true
sudo rm -rf /srv/odoo-backups /srv/node-exporter-textfile
rm -f prod/env/.env.prod edge/env/.env.edge backup/env/.env.backup staging/env/.env.staging monitoring/env/.env.monitoring
git checkout edge/config/traefik-dynamic.yml
```

En el dashboard de Cloudflare: **Storage & databases → R2 →** el bucket **→ Settings → Delete bucket** (vaciarlo primero si lo pide), y **Networking → Tunnels →** el tunnel **→ Delete**.

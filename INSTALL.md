# Instalación

Esta feature se opera con comandos `docker`/`docker compose` directos (el Makefile es una feature separada, más adelante).

Secuencia completa, de punta a punta:

1. Red y volumen compartidos (bootstrap, una sola vez)
2. Build de la imagen de Odoo
3. Stack de producción
4. Stack `edge` (Traefik + Cloudflare Tunnel)
5. Stack `backup` (Postgres RO + GPG + R2)
6. Stack `staging` efímero (restore + anonimización + auto-teardown)
7. Stack `monitoring` (Prometheus + Grafana + Loki + exporters)
8. Desarme (solo si esto fue una prueba, no un despliegue definitivo)

## 1. Red y volumen compartidos (bootstrap, una sola vez)

`prod` y `edge` se conectan por una red Docker externa compartida, `prod`/`backup` comparten el volumen del filestore de Odoo, y `staging` vive en su propia red aislada (Traefik es el único que se une a ambas):

```bash
docker network create odoo-shared
docker network create staging-net
docker volume create odoo-data
```

## 2. Build de la imagen

```bash
docker build -f docker/Dockerfile -t odoo-prod:$(git rev-parse --short HEAD) .
```

Verificar que quedó etiquetada por commit y corre como `odoo` (no root):

```bash
docker inspect --format '{{.Config.User}}' odoo-prod:$(git rev-parse --short HEAD)   # → odoo
```

## 3. Stack de producción

```bash
cp env/.env.prod.example env/.env.prod   # completar con credenciales reales, nunca commitear
docker compose -f docker/docker-compose.prod.yml up -d
docker compose -f docker/docker-compose.prod.yml ps   # confirmar que los 3 servicios están healthy
```

Primera vez (base vacía): inicializar con el módulo `base`:

```bash
docker compose -f docker/docker-compose.prod.yml run --rm odoo odoo -d odoo -i base --stop-after-init
docker compose -f docker/docker-compose.prod.yml restart odoo
```

## 4. Stack `edge` (Traefik + Cloudflare Tunnel)

Crear el Tunnel en el dashboard de Cloudflare — **Networking → Tunnels → Create a tunnel**:

1. Elegir el conector `Docker` y ponerle un nombre.
2. Copiar el comando de instalación que se muestra — el token va incluido ahí (empieza con `eyJ...`), es el mismo valor que `TUNNEL_TOKEN`.
3. Ir a la pestaña **Routes** del tunnel recién creado → **Add route → Published application**.
4. Completar **Subdomain** + **Domain** (el hostname público que vas a usar) y dejar **Path** vacío.
5. En **Service URL**, escribir `http://traefik:80` (un solo campo, protocolo incluido — no hay campos separados de tipo/puerto).
6. Anotar el hostname completo resultante (ej. `odoo.tudominio.com`) — tiene que coincidir exactamente con `config/traefik-dynamic.yml`.

Igualar ese hostname en la config de Traefik:

```bash
sed -i "s/odoo.miempresa.com/<tu-hostname-real>/g" config/traefik-dynamic.yml
```

Levantar:

```bash
cp env/.env.edge.example env/.env.edge
# En env/.env.edge: TUNNEL_TOKEN=<el token del paso anterior>
docker compose -f docker/docker-compose.edge.yml up -d
docker compose -f docker/docker-compose.edge.yml ps   # traefik y cloudflared, ambos healthy
docker compose -f docker/docker-compose.edge.yml logs cloudflared --tail 20   # confirmar "Registered tunnel connection", sin errores de token
```

Verificar **desde afuera del servidor** (tu laptop, no el servidor mismo — para probar el camino completo por internet, no solo la red interna):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://<tu-hostname-real>/web/health
```

Debería dar `200` (esperar 1-2 minutos si da error de TLS/DNS recién creado el Tunnel).

## 5. Stack `backup` (Postgres RO + restic → local + R2)

`restic` provee el cifrado en reposo, la deduplicación y la retención GFS — no hay paso manual de GPG ni lógica de calendario. Cada corrida hace un snapshot (DB + filestore juntos) en el repo local y lo copia al repo R2.

Crear el bucket y las credenciales en el dashboard de Cloudflare — **Storage & databases → R2 → Overview**:

1. **Create bucket** → nombre del bucket, elegir location y storage class por defecto.
2. En la misma pantalla de R2 Overview, sección **API Tokens** → **Manage** → **Create Account API token** (o **User API token**).
3. Permisos: **Object Read & Write**. Alcance: **Apply to specific buckets only**, seleccionando el bucket recién creado.
4. **Create API Token** → copiar `Access Key ID` y `Secret Access Key` de inmediato (no se pueden volver a ver después).
5. Anotar el **endpoint** (`https://<account-id>.r2.cloudflarestorage.com`) — aparece en la misma pantalla de confirmación y en R2 Overview.

Crear (una sola vez) el rol de Postgres de solo lectura:

```bash
export BACKUP_DB_PASSWORD=elegir-un-password   # el mismo valor que va después en env/.env.backup
./scripts/setup-backup-role.sh   # lee POSTGRES_USER de env/.env.prod automáticamente; seguro de re-correr
```

Preparar la carpeta de los repos y la config:

```bash
sudo mkdir -p /srv/odoo-backups
cp env/.env.backup.example env/.env.backup
```

Completar `env/.env.backup` con los datos del bucket recién creado:

```bash
PGPASSWORD=<mismo valor que BACKUP_DB_PASSWORD>
RESTIC_PASSWORD=elegir-una-passphrase          # guardarla fuera del server: sin ella los backups son irrecuperables
RESTIC_REPOSITORY_LOCAL=/backups/restic
RESTIC_REPOSITORY_R2=s3:https://<account-id>.r2.cloudflarestorage.com/<nombre-del-bucket>
AWS_ACCESS_KEY_ID=<Access Key ID>
AWS_SECRET_ACCESS_KEY=<Secret Access Key>
```

Correr el backup (la primera corrida hace `restic init` de ambos repos automáticamente):

```bash
docker compose -f docker/docker-compose.backup.yml run --rm backup
```

Confirmar el snapshot en ambos repos:

```bash
docker compose -f docker/docker-compose.backup.yml run --rm --entrypoint restic backup -r /backups/restic snapshots
# R2: mismo comando con -r "$RESTIC_REPOSITORY_R2" (requiere las AWS_* del env/.env.backup)
```

**Verificar el round-trip de restore** (confirma que el backup es genuinamente recuperable, no solo que el snapshot existe):

```bash
docker compose -f docker/docker-compose.backup.yml run --rm --entrypoint restic backup \
  -r /backups/restic restore latest --target /backups/restore-test
# El dump plano queda en /srv/odoo-backups/restore-test/.../db.sql →
# cargarlo en una DB vacía con psql confirma que la DB es recuperable;
# el directorio del filestore recuperado confirma el otro medio backup.
sudo rm -rf /srv/odoo-backups/restore-test
```

> **Migración desde el backup viejo (feature 003):** al reemplazar el script, la poda GFS en bash desaparece, así que los `.gpg` viejos (locales en `/srv/odoo-backups` y prefijos `daily/weekly/monthly` en R2) **ya no se podan solos**. Tras ≥14 días corriendo restic sin problemas (cubre la retención diaria), borrarlos a mano una única vez: `sudo rm -f /srv/odoo-backups/*.gpg` y eliminar los prefijos `daily/`, `weekly/`, `monthly/` del bucket en el dashboard de R2.

Instalar el timer diario:

```bash
sudo cp systemd/odoo-backup.service systemd/odoo-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now odoo-backup.timer
systemd-analyze verify systemd/odoo-backup.service systemd/odoo-backup.timer
```

## 6. Stack `staging` efímero (restore + anonimización + auto-teardown)

Réplica fiel de prod a menor escala (mismo modelo multiproceso, sin `dev_mode`), en su propia red aislada — no comparte `odoo-shared` con prod. Se levanta on-demand, restaura el último backup de prod y lo anonimiza **antes** de arrancar Odoo, y se autodestruye a las ~3h.

Agregar la segunda ruta al mismo Tunnel de Cloudflare creado en el paso 4 — dashboard → el mismo tunnel → **Routes → Add route → Published application**:

1. **Subdomain** `staging`, mismo **Domain** que prod, **Path** vacío.
2. **Service URL**: `http://traefik:80` (igual que prod — Traefik distingue por `Host`, no por Tunnel).

Igualar el hostname en la config de Traefik:

```bash
sed -i "s/staging.miempresa.com/staging.<tu-dominio-real>/g" config/traefik-dynamic.yml
```

Completar credenciales:

```bash
cp env/.env.staging.example env/.env.staging   # completar con credenciales reales, nunca commitear
```

Levantar staging (orden crítico automático: restore → anonimización → recién Odoo):

```bash
./scripts/staging-up.sh
docker compose -f docker/docker-compose.staging.yml ps   # los 4 servicios healthy
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://staging.<tu-dominio-real>/web/health   # 200
```

**Verificar la anonimización** (confirma que ningún dato real de cliente quedó expuesto):

```bash
docker compose -f docker/docker-compose.staging.yml exec -T db psql -U "$POSTGRES_USER" -d odoo_staging \
  -c "SELECT count(*) FROM ir_mail_server WHERE active;"   # → 0
```

Extender la sesión ~3h más si hace falta:

```bash
./scripts/staging-extend.sh
```

Bajar manualmente antes de que el timer la fuerce (o pedir un ciclo nuevo — `staging-up.sh` hace teardown + fresh restore si staging ya está activa):

```bash
./scripts/staging-down.sh
```

Instalar el teardown de boot (para que un reinicio del server nunca deje staging colgada comiendo RAM):

```bash
sudo cp systemd/staging-teardown-boot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable staging-teardown-boot.service
systemd-analyze verify systemd/staging-teardown-boot.service
```

## 7. Stack `monitoring` (Prometheus + Grafana + Loki + exporters)

Stack siempre-arriba, en `odoo-shared` (sin publicar puertos). Recolecta métricas de host/contenedores/Postgres prod, centraliza logs de todos los contenedores, y expone Grafana en `grafana.miempresa.com` por el edge existente.

Crear (una sola vez) el rol de Postgres de solo lectura para el exporter:

```bash
export MONITORING_DB_PASSWORD=elegir-un-password   # el mismo valor que va después en env/.env.monitoring
./scripts/setup-monitoring-role.sh   # lee POSTGRES_USER de env/.env.prod automáticamente; seguro de re-correr
```

Agregar la tercera ruta al mismo Tunnel de Cloudflare creado en el paso 4 — dashboard → el mismo tunnel → **Routes → Add route → Published application**:

1. **Subdomain** `grafana`, mismo **Domain** que prod, **Path** vacío.
2. **Service URL**: `http://traefik:80` (igual que prod/staging — Traefik distingue por `Host`).

Igualar el hostname en la config de Traefik:

```bash
sed -i "s/grafana.miempresa.com/grafana.<tu-dominio-real>/g" config/traefik-dynamic.yml
```

**Proteger `grafana.<tu-dominio-real>` con Cloudflare Access** (Access intercepta la request antes de que llegue a Grafana; el login propio de Grafana es la segunda capa) — dashboard → **Zero Trust → Access → Applications → Add an application**:

1. Tipo de aplicación: **Self-hosted**.
2. **Application domain**: el hostname `grafana.<tu-dominio-real>` recién creado.
3. En la política de acceso, agregar una regla **Include** con tu email (o el dominio de email del equipo) — solo esa identidad puede pasar.
4. Método de login: **One-time PIN** (por email) alcanza para un operador único; no requiere IdP externo.
5. Guardar — a partir de acá, cualquier visita a `grafana.<tu-dominio-real>` pide autenticación de Cloudflare Access antes de mostrar el login de Grafana.

Completar credenciales:

```bash
cp env/.env.monitoring.example env/.env.monitoring   # completar con credenciales reales (el password de MONITORING_DB_PASSWORD va embebido en el DSN de DATA_SOURCE_NAME, no como variable separada; también SMTP y OPERATOR_EMAIL), nunca commitear
```

Levantar:

```bash
docker compose -f docker/docker-compose.monitoring.yml up -d
docker compose -f docker/docker-compose.monitoring.yml ps   # los 7 servicios healthy/running
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://grafana.<tu-dominio-real>   # 200 (o el desafío de Cloudflare Access)
```

Confirmar que Prometheus tiene todos los targets arriba:

```bash
docker compose -f docker/docker-compose.monitoring.yml exec -T prometheus wget -qO- http://localhost:9090/api/v1/targets
```

Operación diaria (hasta que el Makefile lo envuelva — roadmap B010): `docker compose -f docker/docker-compose.monitoring.yml up -d` / `down` / `logs -f <servicio>`.

## 8. Desarme (solo si esto fue una prueba)

```bash
docker compose -f docker/docker-compose.monitoring.yml down -v
docker compose -f docker/docker-compose.staging.yml down -v
sudo systemctl stop odoo-staging-teardown.timer 2>/dev/null || true
sudo systemctl disable --now staging-teardown-boot.service 2>/dev/null || true
docker compose -f docker/docker-compose.backup.yml down
docker compose -f docker/docker-compose.edge.yml down
docker compose -f docker/docker-compose.prod.yml down -v
docker network rm odoo-shared staging-net
docker volume rm odoo-data
sudo rm -rf /srv/odoo-backups
rm -f env/.env.prod env/.env.edge env/.env.backup env/.env.staging env/.env.monitoring
git checkout config/traefik-dynamic.yml
```

En el dashboard de Cloudflare: **Storage & databases → R2 →** el bucket **→ Settings → Delete bucket** (vaciarlo primero si lo pide), y **Networking → Tunnels →** el tunnel **→ Delete**.

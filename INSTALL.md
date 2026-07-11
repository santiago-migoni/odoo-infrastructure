# Instalación

Esta feature se opera con comandos `docker`/`docker compose` directos (el Makefile es una feature separada, más adelante).

Secuencia completa, de punta a punta:

1. Red y volumen compartidos (bootstrap, una sola vez)
2. Build de la imagen de Odoo
3. Stack de producción
4. Stack `edge` (Traefik + Cloudflare Tunnel)
5. Stack `backup` (Postgres RO + GPG + R2)
6. Desarme (solo si esto fue una prueba, no un despliegue definitivo)

## 1. Red y volumen compartidos (bootstrap, una sola vez)

`prod` y `edge` se conectan por una red Docker externa compartida, y `prod`/`backup` comparten el volumen del filestore de Odoo:

```bash
docker network create odoo-shared
docker volume create odoo-data
```

## 2. Build de la imagen

```bash
docker build -t odoo-prod:$(git rev-parse --short HEAD) .
```

Verificar que quedó etiquetada por commit y corre como `odoo` (no root):

```bash
docker inspect --format '{{.Config.User}}' odoo-prod:$(git rev-parse --short HEAD)   # → odoo
```

## 3. Stack de producción

```bash
cp .env.prod.example .env.prod   # completar con credenciales reales, nunca commitear
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps   # confirmar que los 3 servicios están healthy
```

Primera vez (base vacía): inicializar con el módulo `base`:

```bash
docker compose -f docker-compose.prod.yml run --rm odoo odoo -d odoo -i base --stop-after-init
docker compose -f docker-compose.prod.yml restart odoo
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
cp .env.edge.example .env.edge
# En .env.edge: TUNNEL_TOKEN=<el token del paso anterior>
docker compose -f docker-compose.edge.yml up -d
docker compose -f docker-compose.edge.yml ps   # traefik y cloudflared, ambos healthy
docker compose -f docker-compose.edge.yml logs cloudflared --tail 20   # confirmar "Registered tunnel connection", sin errores de token
```

Verificar **desde afuera del servidor** (tu laptop, no el servidor mismo — para probar el camino completo por internet, no solo la red interna):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://<tu-hostname-real>/web/health
```

Debería dar `200` (esperar 1-2 minutos si da error de TLS/DNS recién creado el Tunnel).

## 5. Stack `backup` (Postgres RO + GPG + R2)

Crear el bucket y las credenciales en el dashboard de Cloudflare — **Storage & databases → R2 → Overview**:

1. **Create bucket** → nombre del bucket, elegir location y storage class por defecto.
2. En la misma pantalla de R2 Overview, sección **API Tokens** → **Manage** → **Create Account API token** (o **User API token**).
3. Permisos: **Object Read & Write**. Alcance: **Apply to specific buckets only**, seleccionando el bucket recién creado.
4. **Create API Token** → copiar `Access Key ID` y `Secret Access Key` de inmediato (no se pueden volver a ver después).
5. Anotar el **endpoint** (`https://<account-id>.r2.cloudflarestorage.com`) — aparece en la misma pantalla de confirmación y en R2 Overview.

Crear (una sola vez) el rol de Postgres de solo lectura:

```bash
export BACKUP_DB_PASSWORD=elegir-un-password   # el mismo valor que va después en .env.backup
./scripts/setup-backup-role.sh   # lee POSTGRES_USER de .env.prod automáticamente; seguro de re-correr
```

Preparar la carpeta de retención local y la config:

```bash
sudo mkdir -p /srv/odoo-backups
cp .env.backup.example .env.backup
```

Completar `.env.backup` con los datos del bucket recién creado:

```bash
PGPASSWORD=<mismo valor que BACKUP_DB_PASSWORD>
GPG_PASSPHRASE=elegir-una-passphrase
RCLONE_DEST=r2:<nombre-del-bucket>
RCLONE_CONFIG_R2_TYPE=s3
RCLONE_CONFIG_R2_PROVIDER=Cloudflare
RCLONE_CONFIG_R2_ACCESS_KEY_ID=<Access Key ID>
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=<Secret Access Key>
RCLONE_CONFIG_R2_ENDPOINT=<endpoint>
```

Correr el backup:

```bash
docker compose -f docker-compose.backup.yml run --rm backup
```

Confirmar que llegó a R2 (dashboard, o por CLI si tenés `rclone` en el host con la misma config):

```bash
rclone lsf r2:<nombre-del-bucket>/daily/
```

**Verificar el round-trip de descifrado** (confirma que el backup es genuinamente recuperable, no solo que el archivo tiene el formato correcto):

```bash
gpg --batch --yes --passphrase "$(grep '^GPG_PASSPHRASE=' .env.backup | cut -d= -f2)" \
  --decrypt /srv/odoo-backups/db-*.dump.gpg > /tmp/restored.dump
pg_restore --list /tmp/restored.dump | head -5   # debe listar objetos del dump sin error
rm /tmp/restored.dump
```

**Verificar `weekly`/`monthly`** sin esperar al domingo/día 1 del mes (no cambiar la fecha del sistema — el servidor corre otras cosas): repetir a mano los mismos `rclone copy` que haría el script para esa rama, contra el backup recién generado:

```bash
rclone copy /srv/odoo-backups/db-*.dump.gpg r2:<nombre-del-bucket>/weekly/
rclone copy /srv/odoo-backups/filestore-*.tar.gz.gpg r2:<nombre-del-bucket>/weekly/
rclone lsf r2:<nombre-del-bucket>/weekly/   # confirmar que llegaron
```

Instalar el timer diario:

```bash
sudo cp systemd/odoo-backup.service systemd/odoo-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now odoo-backup.timer
systemd-analyze verify systemd/odoo-backup.service systemd/odoo-backup.timer
```

## 6. Desarme (solo si esto fue una prueba)

```bash
docker compose -f docker-compose.backup.yml down
docker compose -f docker-compose.edge.yml down
docker compose -f docker-compose.prod.yml down -v
docker network rm odoo-shared
docker volume rm odoo-data
sudo rm -rf /srv/odoo-backups
rm -f .env.prod .env.edge .env.backup
git checkout config/traefik-dynamic.yml
```

En el dashboard de Cloudflare: **Storage & databases → R2 →** el bucket **→ Settings → Delete bucket** (vaciarlo primero si lo pide), y **Networking → Tunnels →** el tunnel **→ Delete**.

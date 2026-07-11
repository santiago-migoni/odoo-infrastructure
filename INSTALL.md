# Instalación / build manual

Esta feature se opera con comandos `docker`/`docker compose` directos (el Makefile es una feature separada, más adelante).

Secuencia completa desde cero:

1. Crear la red y el volumen compartidos (una sola vez)
2. Build de la imagen de Odoo
3. Levantar el stack de producción
4. Levantar el stack `edge` (Traefik + Cloudflare Tunnel)
5. Configurar y levantar el stack `backup`

## 1. Red y volumen compartidos (bootstrap, una sola vez)

`prod` y `edge` se conectan por una red Docker externa compartida, y `prod`/`backup` comparten el volumen del filestore de Odoo — hay que crear ambos antes de levantar cualquier stack por primera vez (`docker compose up` falla con "network/volume not found" si no existen):

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

## 3. Levantar el stack de producción

```bash
cp .env.prod.example .env.prod   # completar con credenciales reales, nunca commitear
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps   # confirmar que los 3 servicios están healthy
```

## 4. Levantar el stack `edge` (Traefik + Cloudflare Tunnel)

```bash
cp .env.edge.example .env.edge   # completar con el TUNNEL_TOKEN real, nunca commitear
docker compose -f docker-compose.edge.yml up -d
docker compose -f docker-compose.edge.yml ps   # confirmar que traefik está healthy
```

Sin un `TUNNEL_TOKEN` real todavía, `cloudflared` va a fallar al arrancar (esperado — ver spec de la feature `edge`). Traefik puede probarse solo, sin depender de `cloudflared`, pegándole desde otro contenedor en la red `odoo-shared`:

```bash
docker run --rm --network odoo-shared curlimages/curl -s -H "Host: odoo.miempresa.com" http://traefik/web/health
```

## 5. Stack `backup`

Crear (una sola vez) el rol de Postgres de solo lectura que usa el backup, contra `prod` ya levantado:

```bash
export BACKUP_DB_PASSWORD=elegir-un-password   # el mismo valor que vas a poner en .env.backup
./scripts/setup-backup-role.sh   # lee POSTGRES_USER de .env.prod automáticamente
```

Preparar la carpeta de retención local y correr el backup a mano:

```bash
sudo mkdir -p /srv/odoo-backups
cp .env.backup.example .env.backup   # completar con credenciales reales, nunca commitear
docker compose -f docker-compose.backup.yml run --rm backup
```

Para probar sin credenciales reales de R2, dejar `RCLONE_DEST` en `.env.backup` apuntando a una ruta de filesystem plana (ej. `/tmp/backup-test`) en vez de `r2:bucket` — `rclone` la trata como backend local automáticamente, sin necesitar ningún `RCLONE_CONFIG_*`.

Instalar el timer diario:

```bash
sudo cp systemd/odoo-backup.service systemd/odoo-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now odoo-backup.timer
```

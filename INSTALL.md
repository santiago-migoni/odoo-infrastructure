# Instalación / build manual

Esta feature se opera con comandos `docker`/`docker compose` directos (el Makefile es una feature separada, más adelante).

Secuencia completa desde cero:

1. Crear la red compartida (una sola vez)
2. Build de la imagen de Odoo
3. Levantar el stack de producción
4. Levantar el stack `edge` (Traefik + Cloudflare Tunnel)

## 1. Red compartida (bootstrap, una sola vez)

`prod` y `edge` se conectan por una red Docker externa compartida — hay que crearla antes de levantar cualquiera de los dos stacks por primera vez (`docker compose up` falla con "network not found" si no existe):

```bash
docker network create odoo-shared
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

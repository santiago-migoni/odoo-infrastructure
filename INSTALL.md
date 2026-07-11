# Instalación / build manual

Esta feature se opera con comandos `docker`/`docker compose` directos (el Makefile es una feature separada, más adelante).

## Build de la imagen

```bash
docker build -t odoo-prod:$(git rev-parse --short HEAD) .
```

Verificar que quedó etiquetada por commit y corre como `odoo` (no root):

```bash
docker inspect --format '{{.Config.User}}' odoo-prod:$(git rev-parse --short HEAD)   # → odoo
```

## Red compartida (bootstrap, una sola vez)

`prod` y `edge` se conectan por una red Docker externa compartida — hay que crearla antes de levantar cualquiera de los dos stacks por primera vez (en cualquier orden, `docker compose up` falla con "network not found" si no existe):

```bash
docker network create odoo-shared
```

## Levantar el stack de producción

```bash
cp .env.prod.example .env.prod   # completar con credenciales reales, nunca commitear
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps   # confirmar que los 3 servicios están healthy
```

## Levantar el stack `edge` (Traefik + Cloudflare Tunnel)

```bash
cp .env.edge.example .env.edge   # completar con el TUNNEL_TOKEN real, nunca commitear
docker compose -f docker-compose.edge.yml up -d
docker compose -f docker-compose.edge.yml ps   # confirmar que traefik está healthy
```

Sin un `TUNNEL_TOKEN` real todavía, `cloudflared` va a fallar al arrancar (esperado — ver spec de la feature `edge`). Traefik puede probarse solo, sin `cloudflared`, apuntando una request con el header `Host` correcto desde otro contenedor en la red `odoo-shared`.

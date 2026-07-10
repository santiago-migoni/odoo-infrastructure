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

## Levantar el stack de producción

```bash
cp .env.prod.example .env.prod   # completar con credenciales reales, nunca commitear
docker compose -f docker-compose.prod.yml up -d
docker compose -f docker-compose.prod.yml ps   # confirmar que los 3 servicios están healthy
```

## Exposición temporal para probar (antes de que exista `edge`)

```bash
cp docker-compose.override.yml.example docker-compose.override.yml   # gitignored, no se commitea
docker compose -f docker-compose.prod.yml up -d
curl http://127.0.0.1:8069/web/health
```

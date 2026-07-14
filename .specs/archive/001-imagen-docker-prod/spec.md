---
name: imagen-docker-prod
code: SPEC-001
version: R03
date: 2026-07-10
status: Converged
---

# Spec: Imagen Docker + Stack de Producción

## Summary

Construir la imagen Docker propia de Odoo 19 (con addons custom incluidos) y el stack `docker-compose.prod.yml` (Odoo + Postgres + PgBouncer) que la ejecuta de forma reproducible, saludable y sin exponer puertos al host.

## User Stories

### US1 — Imagen reproducible por commit (P1)

Como operador, quiero que la imagen de Odoo se construya desde un `Dockerfile` versionado con mis addons custom incluidos (organizados por categoría, cada uno pineado a un commit/rama específico), para que cada deploy quede atado a una versión reproducible.

**Acceptance Scenarios**:
- **Given** los addons custom (uno por categoría, cada uno pineado a un commit/rama específico), **When** se construye la imagen, **Then** queda etiquetada con el tag de versión mayor (`odoo:19.0`) y con el commit SHA del build — nunca `latest`.
- **Given** la imagen construida, **When** se inspecciona el usuario del proceso, **Then** corre como `odoo` (UID 101), nunca como `root`.
- **Given** un addon custom con su propio `requirements.txt`, **When** se construye la imagen, **Then** esas dependencias Python quedan instaladas dentro de la imagen.

### US2 — Stack de producción arranca sano (P1)

Como operador, quiero que `docker compose up` levante Odoo, Postgres y PgBouncer conectados entre sí en una red interna de Docker, sin publicar ningún puerto al host, para que el stack sea utilizable de forma segura por defecto.

**Acceptance Scenarios**:
- **Given** el stack recién levantado, **When** Postgres todavía no está listo, **Then** Odoo espera (`depends_on: condition: service_healthy`) y no arranca antes.
- **Given** el stack corriendo, **When** se consulta `/web/health` desde dentro de la red interna, **Then** responde exitosamente.
- **Given** el stack corriendo, **When** se inspeccionan los contenedores, **Then** ninguno publica un puerto al host (salvo la excepción temporal de US3).
- **Given** el stack corriendo, **When** se inspecciona `odoo.conf`, **Then** `list_db = False` y `proxy_mode = True` están activos.

### US3 — Exposición temporal para validar sin `edge` (P2)

Como operador, quiero poder exponer Odoo momentáneamente solo en `localhost` para validar el stack de punta a punta antes de que exista el stack `edge` (Traefik + Cloudflare Tunnel, feature siguiente).

**Acceptance Scenarios**:
- **Given** la necesidad de probar el stack manualmente, **When** se habilita la exposición temporal, **Then** Odoo es alcanzable en `127.0.0.1:8069` — nunca en `0.0.0.0` ni en la IP de la red.
- **Given** que la feature `edge` ya existe, **When** se integra, **Then** esta exposición temporal deja de ser necesaria (ver Clarifications sobre cómo se retira).

> Nota para la feature `edge`: al integrarla, su spec debe indicar explícitamente si `docker-compose.override.yml.example` de esta feature se elimina o queda solo como referencia histórica.

### US4 — Sizing aplicado y exigible (P2)

Como operador, quiero que los límites de recursos documentados en `docs/infrastructure-design.md` estén aplicados tanto a nivel proceso de Odoo como a nivel Docker Compose, para que este stack por sí solo no ponga en riesgo la RAM compartida del servidor.

**Acceptance Scenarios**:
- **Given** `odoo.conf`, **When** se inspecciona, **Then** `workers=3`, `max_cron_threads=2`, `limit_memory_soft=1638MiB` (`1717567488` bytes), `limit_memory_hard=2048MiB` (`2147483648` bytes).
- **Given** `docker-compose.prod.yml`, **When** se inspecciona, **Then** cada servicio tiene `mem_limit`/`cpus` definidos, además de los límites propios de Odoo.
- **Given** Postgres, **When** se inspecciona su configuración, **Then** `shared_buffers=1.5GiB`, `work_mem=64MB`, `max_connections=100`, `random_page_cost=1.1`.
- **Given** PgBouncer, **When** se inspecciona su configuración, **Then** `pool_mode=transaction`, `default_pool_size=20`, `max_client_conn=200`, `listen_port=6432`.

## Edge Cases

- El build de la imagen falla (ej. un addon custom no instala sus requirements) → el build debe fallar visiblemente, nunca producir una imagen "medio construida" etiquetada como válida.
- Postgres tarda más de lo esperado en levantar (disco lento, primera inicialización) → Odoo debe seguir esperando por el healthcheck en vez de arrancar y fallar en loop.
- Se intenta escribir sobre `odoo.conf` desde dentro del contenedor (está montado `:ro`) → debe fallar sin tumbar el contenedor.

## Explicit Non-Goals

- Reverse proxy, TLS, Cloudflare Tunnel o cualquier exposición pública real — eso es la feature `edge` (siguiente).
- Stack de `staging`, `backup` o `monitoring` — features separadas posteriores.
- Makefile y pipeline de CI/CD — feature separada (última del roadmap). Esta feature se opera con comandos `docker compose` directos.
- Activación real de módulos Enterprise u OCA — solo la estructura de `addons_path` queda lista, sin módulos instalados.

## Clarifications

- La exposición temporal de US3 (`127.0.0.1:8069`) se implementa como `docker-compose.override.yml` separado y **no versionado** (gitignored) — `docker-compose.prod.yml` nunca tiene, ni comentado, un mapeo de puertos. Coherente con el principio de la constitución "ningún contenedor publica puertos al host".

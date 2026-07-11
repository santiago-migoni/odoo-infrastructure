---
name: edge-stack
code: PLAN-002
version: R01
date: 2026-07-10
---

# Plan: Stack `edge` (Traefik + Cloudflare Tunnel)

## Approach

`docker-compose.edge.yml` con dos servicios (`traefik`, `cloudflared`) sobre una red Docker **externa y compartida** con el stack `prod` (única forma real de que Traefik alcance `odoo:8069`/`8072` por nombre, sin depender de que ambos compose se invoquen desde el mismo directorio/project implícito). Traefik rutea por hostname vía **file provider** (config estática, sin Docker provider ni socket montado — decisión de la sesión de `/clarify`, por el riesgo de dar acceso root al host al contenedor con salida a internet). `cloudflared` corre en modo remotely-managed (`TUNNEL_TOKEN`), con el mapeo hostname→`http://traefik:80` configurado del lado de Cloudflare (dashboard Zero Trust), no en este repo.

## Constitution Check

- **Tech stack**: Traefik + Cloudflare Tunnel — coincide con lo definido en la constitución.
- **Code principles aplicables**: "ningún contenedor publica puertos al host"; "RAM es el recurso más restrictivo" (US4 exige sizing explícito).
- **Constraints**: sin IP pública fija asumida, toda exposición externa vía Cloudflare Tunnel — coincide.
- **Desvío mínimo necesario sobre la feature 1**: `docker-compose.prod.yml` requiere un cambio acotado (red externa compartida) — ya estaba pre-autorizado en el pedido original de esta feature ("sin tocar el stack prod salvo lo necesario para conectarlo a la red de edge"). No se agregan labels de routing ahí, solo la red.
- Sin conflictos detectados.

## Architecture

```text
Internet ──▶ Cloudflare Edge (TLS) ──▶ cloudflared ──▶ (red "odoo-shared") ──▶ traefik:80
                                                                                  │
                                                          ┌───────────────────────┼───────────────────────┐
                                                          │                       │                       │
                                                   Host=odoo.miempresa.com  Host=... && /websocket   (futuro: staging)
                                                          │                       │
                                                          ▼                       ▼
                                                     odoo:8069                odoo:8072
```

- Red **`odoo-shared`**: externa, creada una sola vez (`docker network create odoo-shared`), referenciada por ambos compose (`prod` y `edge`) con `external: true`. Reemplaza la red `internal` project-scoped que hoy crea `docker-compose.prod.yml` — es el único cambio real sobre la feature 1.
- Traefik no tiene acceso al socket de Docker ni al API — su única fuente de configuración es el archivo de file provider.
- `cloudflared` no conoce IPs ni puertos del host — solo `http://traefik:80` dentro de `odoo-shared`.
- TLS se termina en el edge de Cloudflare; todo lo interno (`cloudflared`→`traefik`→`odoo`) es HTTP plano dentro de la red Docker.

## File Structure

```text
odoo-infrastructure/
├── docker-compose.edge.yml       ← nuevo. Servicios traefik/cloudflared, sin ports:, healthcheck en traefik, mem_limit/cpus en ambos, red odoo-shared externa
├── docker-compose.prod.yml       ← modificado. Red `internal` → `odoo-shared` externa (único cambio; sin labels de routing)
├── docker-compose.override.yml.example ← eliminado (ya no hace falta con edge funcionando, ver spec.md Clarifications)
├── config/
│   ├── traefik.yml              ← nuevo. Config estática: entryPoint web (:80), providers.file, api/dashboard deshabilitado
│   └── traefik-dynamic.yml      ← nuevo. File provider: routers `odoo` (Host, →8069) y `odoo-ws` (Host+PathPrefix /websocket, →8072, mayor prioridad), límites de tamaño/timeout
├── .env.edge.example             ← nuevo. Plantilla con `TUNNEL_TOKEN` (vacío/placeholder) — el `.env.edge` real gitignored
├── .gitignore                    ← modificado. Agrega `.env.edge`
└── INSTALL.md                    ← modificado. Agrega: bootstrap de `odoo-shared`, build/up de `edge`, cómo obtener y setear `TUNNEL_TOKEN` real
```

## Data Model

N/A — sin modelo de datos propio.

## API / Interface Contracts

- **`traefik`**: sin variables de entorno — toda su config vive en `config/traefik.yml` (estática) y `config/traefik-dynamic.yml` (routers), montados `:ro`.
- **`cloudflared`** (imagen oficial `cloudflare/cloudflared`): `TUNNEL_TOKEN` (vía `.env.edge`) — token de un tunnel remotely-managed creado en el dashboard de Cloudflare Zero Trust. El mapeo hostname público → `http://traefik:80` se configura del lado de Cloudflare (Public Hostname del tunnel), no en este repo.
- **Routers de Traefik** (en `traefik-dynamic.yml`):
  - `odoo-ws`: `Host(\`odoo.miempresa.com\`) && PathPrefix(\`/websocket\`)` → `http://odoo:8072`, prioridad alta explícita.
  - `odoo`: `Host(\`odoo.miempresa.com\`)` → `http://odoo:8069`.
  - Traefik pasa `Upgrade`/`Connection` de forma nativa en proxying HTTP — no hace falta middleware adicional para websocket (a diferencia de Nginx).

## Dependencies

- `traefik:v3.7.7` (imagen oficial, versión estable fijada al momento de escribir este plan — no el tag flotante `v3`/`v3.7`/`latest`).
- `cloudflare/cloudflared:2026.7.1` (imagen oficial, versión estable fijada al momento de escribir este plan — no `latest`).
- Sin dependencias nuevas de lenguaje/paquetes.

## Risks & Unknowns

- **Red externa compartida (`odoo-shared`) no existe todavía en ningún entorno real.** Debe crearse una vez (`docker network create odoo-shared`) antes de levantar cualquiera de los dos stacks por primera vez. Documentar el bootstrap en `INSTALL.md` — si se omite, ambos `docker compose up` fallan con "network not found".
- **Prioridad de routers en Traefik (file provider).** Confirmar en implementación que el router `odoo-ws` (más específico) efectivamente gana sobre `odoo` para requests a `/websocket` — fijar `priority` explícito en vez de depender del ordenamiento por especificidad de regla, para no depender de un comportamiento implícito.
- **Sizing de `traefik`/`cloudflared`.** Sin dato de referencia preciso (el presupuesto original de `docs/infrastructure-design.md` los agrupaba junto a PgBouncer bajo una única cifra, ya superada por PgBouncer solo). Se fijan valores conservadores para procesos livianos conocidos: `traefik` 128 MiB / 0.5 cpu, `cloudflared` 128 MiB / 0.5 cpu — a validar con `docker inspect` una vez implementado, igual que se hizo en la feature 1.

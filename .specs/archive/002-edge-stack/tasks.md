---
name: edge-stack
code: TASKS-002
version: R01
date: 2026-07-10
---

# Tasks: Stack `edge` (Traefik + Cloudflare Tunnel)

## Phase 1: Setup

- [x] T001 [setup] Eliminar `docker-compose.override.yml.example` (ya no hace falta con `edge` funcionando, ver spec.md Clarifications)
- [x] T002 [setup] Actualizar `.gitignore`: agregar `.env.edge`
- [x] T003 [setup] Documentar en `INSTALL.md` el bootstrap de la red externa compartida: `docker network create odoo-shared` (paso único, antes de levantar `prod` o `edge` por primera vez)

## Phase 2: Ruteo por hostname sin exposición directa (US1)

- [x] T004 [US1] Modificar `docker-compose.prod.yml`: red `internal` → externa `odoo-shared` (`external: true`, `name: odoo-shared`) en la sección `networks:` de nivel de archivo; sin tocar labels ni servicios
- [x] T005 [US1] Escribir `config/traefik.yml`: entryPoint `web` (`:80`), `providers.file` apuntando a `config/traefik-dynamic.yml`, `api`/`dashboard` deshabilitado (sin exponer ni siquiera internamente), `ping: {}` habilitado (requerido por el healthcheck de T008 — `traefik healthcheck --ping` falla sin esto)
- [x] T006 [US1][US3] Escribir `config/traefik-dynamic.yml`: router `odoo-ws` (`Host(\`odoo.miempresa.com\`) && PathPrefix(\`/websocket\`)`, `priority` alto explícito) → `http://odoo:8072`; router `odoo` (`Host(\`odoo.miempresa.com\`)`) → `http://odoo:8069`; middleware `buffering` (`maxRequestBodyBytes` equivalente a 200 MB) aplicado a ambos routers
- [x] T007 [US1][US3] Ajustar `config/traefik.yml`: timeouts de entrypoint/`serversTransport` (equivalente a `proxy_read_timeout 900s`) para no cortar operaciones largas (reportes)
- [x] T008 [US1][US4] Crear `docker-compose.edge.yml`, servicio `traefik` (imagen `traefik:v3.7.7`, pineada — nunca `latest`): monta `config/traefik.yml` y `config/traefik-dynamic.yml` `:ro`, sin `ports:`, red `odoo-shared` (externa), healthcheck (`traefik healthcheck --ping`), `restart: unless-stopped`, `mem_limit: 128m`, `cpus: 0.5`

## Phase 3: `cloudflared` conecta a Traefik por red interna (US2)

- [x] T009 [US2][US4] En `docker-compose.edge.yml`, definir servicio `cloudflared` (imagen `cloudflare/cloudflared:2026.7.1`, pineada — nunca `latest`): `command: tunnel run`, env `TUNNEL_TOKEN` vía `.env.edge`, red `odoo-shared` (externa), sin `ports:`, `restart: unless-stopped`, `mem_limit: 128m`, `cpus: 0.5`
- [x] T010 [P][US2] Crear `.env.edge.example` con `TUNNEL_TOKEN` como placeholder — el `.env.edge` real gitignored

## Verification

- [x] VERIFY US1 — Confirmado. `Host: odoo.miempresa.com` + `/web/health` → 200, misma respuesta y header `Server: Werkzeug` que pegándole directo a `odoo:8069`; `/websocket` → 400 sin header `Server` (firma de gevent en 8072, distinta de la de 8069) — confirma que el router `odoo-ws` (prioridad 100) gana sobre `odoo` (prioridad 1); `docker inspect` confirmó `PortBindings: map[]` en `traefik`
- [x] VERIFY US2 — Confirmado. `cloudflared` con token placeholder logueó `"Provided Tunnel token is not valid"` de forma clara en cada intento (no en silencio); config apunta a `http://traefik:80` (sin `ports:` en el servicio)
- [x] VERIFY US3 — Confirmado el mecanismo: se bajó `maxRequestBodyBytes` a 100 temporalmente, un body de 1000 bytes dio `413` (rechazado antes de llegar al backend), un body chico pasó; restaurado el valor real (209715200 = 200MB) y reverificado el ruteo normal tras el restart. Los timeouts de 900s no se probaron esperando 900s reales (impráctico), pero no introdujeron errores de arranque ni afectaron requests normales
- [x] VERIFY US4 — Confirmado. `docker inspect` mostró `Memory: 134217728` (128MB, coincide con `mem_limit: 128m`) en `traefik` y `cloudflared`; `NanoCpus` reflejó el override local de test, valor real (0.5) sin tocar en los archivos committeados
- [x] VERIFY Edge case — Confirmado, ver US2
- [x] VERIFY Edge case — Confirmado. `Host: no-existe.example.com` → `404` de Traefik, respuesta inmediata
- [x] VERIFY Edge case — Confirmado. Con `odoo` parado, request vía Traefik → `502` en <10s, sin colgarse; `odoo` recuperado después y healthcheck volvió a responder 200
- [x] VERIFY No se crearon archivos fuera de los listados en "File Structure" de `plan.md` — confirmado con `git status --short`
- [x] VERIFY No se agregaron dependencias fuera de las listadas en "Dependencies" de `plan.md` — confirmado, solo `traefik:v3.7.7` y `cloudflare/cloudflared:2026.7.1`

## Phase 4: Convergence

- [x] T011 Verificar con un handshake de upgrade real contra Traefik en `/websocket` — **Confirmado**: primer intento (sin header `Origin`) devolvió `400` con el mensaje específico de gevent `"Empty or missing header(s): origin"` (prueba de que `Upgrade`/`Connection` sí llegaron al backend, ya que gevent llegó a validar el WS handshake en profundidad); segundo intento agregando `Origin` devolvió **`101 Switching Protocols`** — confirmación completa del passthrough nativo de Traefik hasta `odoo:8072` (partial → resuelto)

---
name: edge-stack
code: SPEC-002
version: R01
date: 2026-07-10
status: Converged
---

# Spec: Stack `edge` (Traefik + Cloudflare Tunnel)

## Summary

Construir el stack `docker-compose.edge.yml` (Traefik + `cloudflared`) que expone el stack de producción a internet por hostname, sin publicar ningún puerto al host y sin gestión manual de TLS.

## User Stories

### US1 — Ruteo por hostname sin exposición directa (P1)

Como operador, quiero que Traefik rutee el tráfico entrante por hostname hacia el stack de Odoo correspondiente (vía config estática declarada dentro del propio stack `edge`, sin depender del socket de Docker ni tocar `docker-compose.prod.yml`), para poder exponer la aplicación a internet sin publicar puertos directamente desde ningún contenedor.

**Acceptance Scenarios**:
- **Given** el stack `edge` corriendo en la misma red interna que el stack `prod`, con los routers de Traefik declarados en un archivo de config estática montado por `docker-compose.edge.yml` (apuntando a `odoo:8069`/`odoo:8072` por nombre de servicio en la red compartida), **When** llega una request con `Host: odoo.miempresa.com`, **Then** Traefik la rutea hacia el servicio `odoo` del stack prod.
- **Given** el stack `edge` corriendo, **When** se inspeccionan sus contenedores, **Then** ninguno publica un puerto al host (coherente con el principio de la constitución).
- **Given** una request a `/websocket` con `Host: odoo.miempresa.com`, **When** Traefik la rutea, **Then** va al puerto 8072 del servicio `odoo` con headers `Upgrade`/`Connection: upgrade`; cualquier otra ruta va al puerto 8069.

### US2 — `cloudflared` conecta a Traefik por red interna (P1)

Como operador, quiero que `cloudflared` hable con Traefik exclusivamente por la red interna de Docker, para que la única puerta de entrada real a internet sea el Tunnel de Cloudflare.

**Acceptance Scenarios**:
- **Given** el stack `edge` configurado, **When** se inspecciona la configuración de `cloudflared`, **Then** apunta a `http://traefik:80` (DNS interno de Docker), nunca a `localhost` ni a un puerto del host.
- **Given** que todavía no existe una cuenta/Tunnel real de Cloudflare, **When** se levanta `cloudflared` sin token válido, **Then** el contenedor falla de forma clara (no en silencio) indicando que falta el token — comportamiento esperado, no un bug de esta feature.

### US3 — Límites de request para adjuntos y reportes (P2)

Como operador, quiero que Traefik acepte adjuntos grandes y no cierre conexiones en operaciones largas (reportes), para que el uso normal de Odoo no se vea interrumpido por límites por defecto del proxy.

**Acceptance Scenarios**:
- **Given** una request con un body grande (adjunto), **When** pasa por Traefik, **Then** no se corta por un límite de tamaño por defecto (equivalente a `client_max_body_size 200m` de la referencia de diseño).
- **Given** una operación que tarda varios minutos (ej. generación de reporte), **When** pasa por Traefik, **Then** no se corta por timeout antes de completar (equivalente a `proxy_read_timeout 900s`).

### US4 — Sizing aplicado y exigible (P2)

Como operador, quiero que `traefik` y `cloudflared` tengan límites de recursos explícitos, para mantener la misma disciplina de sizing que el resto de la infraestructura y no asumir RAM sin revisar el presupuesto documentado.

**Acceptance Scenarios**:
- **Given** `docker-compose.edge.yml`, **When** se inspecciona, **Then** los servicios `traefik` y `cloudflared` tienen `mem_limit`/`cpus` definidos (valores exactos a fijar en `/plan` contra el presupuesto de RAM de `docs/infrastructure-design.md`).

## Edge Cases

- `cloudflared` arranca sin token de Tunnel configurado → debe fallar visiblemente (log claro), no quedar en un loop de reintentos silencioso indefinido.
- Traefik recibe una request con un `Host` header que no coincide con ningún router configurado → debe responder con un error claro (404/502 de Traefik), no colgarse ni caer.
- El stack `prod` (feature 1) no está corriendo cuando `edge` sí → Traefik debe reportar el backend como no disponible (502), no crashear.

## Explicit Non-Goals

- Creación real de la cuenta/dominio/Tunnel de Cloudflare — queda como paso manual del operador, fuera de este repo.
- Stack `staging` — el ruteo a `staging.miempresa.com` se agrega cuando exista la feature de staging efímera.
- Validación end-to-end contra Cloudflare real — se prueba solo el comportamiento de Traefik dentro de la red interna; `cloudflared` se deja configurado pero sin token real.
- Makefile y CI/CD — feature separada, esta se opera con `docker compose` directo, igual que la feature 1.
- Dashboard/API de Traefik — deshabilitado. Debug se hace por logs (`docker logs`), no por UI. Si hace falta más adelante, se habilita puntualmente.

## Clarifications

- El `docker-compose.override.yml.example` de la feature 1 (mapeo temporal `127.0.0.1:8069` para probar sin `edge`) se **elimina** como parte de esta feature — ya no hace falta con `edge` funcionando, y dejarlo invitaría a seguir usando ese atajo en vez del camino real.

### Session 2026-07-10

- Q: ¿Cómo descubre Traefik hacia dónde rutear — labels de Docker en `docker-compose.prod.yml`, o config dinámica solo en el stack `edge`? → A (revisado): config estática (file provider) declarada dentro de `docker-compose.edge.yml`, sin Docker provider ni socket montado. La respuesta original (labels de Docker vía socket) se descartó: montar `/var/run/docker.sock` en el contenedor con salida directa a internet (Traefik) equivale a darle acceso root al host si se compromete — riesgo real que no se había señalado al proponerla. Con config estática, `docker-compose.prod.yml` de la feature 1 queda completamente intacto — el costo es mantener a mano el routing de 1-2 hostnames fijos, mínimo dado el alcance.
- Q: ¿Traefik expone dashboard/API, y cómo queda protegido? → A: Deshabilitado por completo — ni siquiera accesible dentro de la red interna. Debug por logs.
- Q: ¿`traefik`/`cloudflared` llevan `mem_limit`/`cpus` explícitos, o se dejan sin límite? → A: Con límites explícitos, misma disciplina que la feature 1 (nueva US4). Valores exactos a fijar en `/plan`.

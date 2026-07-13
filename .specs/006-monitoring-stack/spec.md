---
name: monitoring-stack
code: SPEC-006
version: R00
date: 2026-07-13
status: Converged
---

# Spec: Stack `monitoring`

## Summary

Un stack de observabilidad siempre-arriba (`docker-compose.monitoring.yml`) que recolecta métricas de host, contenedores y Postgres prod (Prometheus + node-exporter + cAdvisor + postgres-exporter-prod), centraliza logs de todos los contenedores (Loki + Promtail) y los presenta en Grafana — expuesto en `grafana.miempresa.com` por el edge existente detrás de Cloudflare Access — con alertas por email cuando la RAM del host, un contenedor caído o Postgres sin conexiones cruzan umbral.

## Clarifications

### Session 2026-07-13

- Q: Valores concretos de retención de Prometheus y Loki → A: 15 días ambos (default parejo; suficiente para diagnóstico semanal, footprint de disco chico dada la cardinalidad baja de un single-tenant).
- Q: Umbral exacto de la alerta de RAM del host → A: >85% de RAM usada sostenido 5 min (justo por encima del peak de diseño ~84% con staging activa; alerta real con poco ruido por picos transitorios).
- Q: ¿El aprovisionamiento de la política de Cloudflare Access para grafana.miempresa.com entra en el alcance? → A: Fuera de alcance — se configura manualmente en el panel de Cloudflare (consistente con cómo se gestionan hoy el túnel y los hostnames del edge), documentado en INSTALL.md. El spec solo exige que Access esté delante de Grafana; no cómo se aprovisiona.

## User Stories

### US1 — Métricas de host, contenedores y Postgres en Prometheus (P1)

Como operador, quiero que Prometheus scrapee node-exporter (host), cAdvisor (por contenedor) y postgres-exporter-prod (DB prod), para tener series históricas de RAM/CPU/disco por servicio — la RAM es el recurso más restrictivo del server y necesito verla en el tiempo, no adivinarla.

**Acceptance Scenarios**:
- **Given** el stack `monitoring` levantado, **When** se consulta `/api/v1/targets` de Prometheus, **Then** `node-exporter`, `cadvisor` y `postgres-exporter-prod` aparecen como targets en estado `up`.
- **Given** Prometheus corriendo, **When** se consulta una métrica de contenedor (ej. `container_memory_usage_bytes`), **Then** devuelve series etiquetadas por contenedor para los servicios de prod, edge y monitoring corriendo en el server.
- **Given** postgres-exporter-prod, **When** scrapea la `db` de prod, **Then** se conecta por la red interna de Docker (sin publicar puertos) con un rol de Postgres de solo lectura dedicado, no el superusuario.
- **Given** cualquiera de los exporters, **When** el stack está definido, **Then** cada servicio tiene `mem_limit` fijado según el presupuesto de RAM de `docs/infrastructure-design.md` (techo, no reserva) — ninguno queda sin techo dado el riesgo de leak documentado de postgres-exporter/Promtail.

### US2 — Logs centralizados de todos los contenedores (P1)

Como operador, quiero los logs de todos los contenedores agregados en Loki vía Promtail y consultables desde Grafana, para no tener que hacer `docker logs` servicio por servicio ni entrar al server.

**Acceptance Scenarios**:
- **Given** Promtail corriendo, **When** un contenedor cualquiera (prod, staging, edge, backup, monitoring) emite un log, **Then** Promtail lo descubre por el socket de Docker y lo envía a Loki etiquetado con el nombre del contenedor y el stack.
- **Given** Loki con logs ingeridos, **When** se consulta desde Grafana (datasource Loki), **Then** se pueden filtrar logs por contenedor y por rango de tiempo.
- **Given** Loki corriendo, **When** los logs superan los 15 días de retención, **Then** Loki los descarta automáticamente — retención acotada para no crecer sin techo en disco (RAM/disco es presupuesto escaso).

### US3 — Grafana expuesto por el edge detrás de Cloudflare Access (P1)

Como operador remoto, quiero acceder a Grafana en `grafana.miempresa.com` sin publicar puertos ni SSH, reutilizando el edge stack, y protegido por Cloudflare Access antes de llegar al login de Grafana.

**Acceptance Scenarios**:
- **Given** el stack `monitoring` y el edge corriendo, **When** se navega a `https://grafana.miempresa.com`, **Then** el tráfico fluye `cloudflared → Traefik → grafana:3000` sin que monitoring publique ningún puerto al host.
- **Given** un visitante sin sesión de Cloudflare Access, **When** intenta abrir `grafana.miempresa.com`, **Then** Cloudflare Access lo intercepta y exige autenticación **antes** de que la request llegue a Grafana.
- **Given** Grafana levantado por primera vez, **When** arranca, **Then** los datasources Prometheus y Loki y los dashboards base quedan aprovisionados por config (provisioning declarativo), no creados a mano por la UI.
- **Given** Grafana detrás de Traefik/Cloudflare, **When** se sirve, **Then** está configurado para operar detrás de reverse proxy (root_url / proxy correcto), análogo a `proxy_mode` en Odoo.

### US4 — Alertas por email en las 3 condiciones críticas (P1)

Como operador, quiero que Grafana Alerting me mande un email cuando la RAM del host cruza umbral, un contenedor esperado está caído, o Postgres se queda sin conexiones disponibles, para enterarme antes de que se caiga prod, sin mirar dashboards.

**Acceptance Scenarios**:
- **Given** reglas de alerta provisionadas, **When** la RAM usada del host supera el 85% sostenido durante 5 min, **Then** Grafana dispara una alerta y envía email al contact point SMTP del operador.
- **Given** un contenedor esperado (ej. `odoo` prod, `db` prod, `traefik`), **When** deja de reportarse `up`/desaparece de las métricas, **Then** se dispara alerta por email.
- **Given** Postgres prod, **When** las conexiones disponibles llegan a ~0 (pool agotado / cerca de `max_connections`), **Then** se dispara alerta por email.
- **Given** las alertas y el contact point, **When** se define el stack, **Then** las reglas y el contact point SMTP están provisionados por config; las credenciales SMTP vienen del `.env` del stack (fuera del repo), no hardcodeadas.

### US5 — Stack siempre-arriba, dentro del presupuesto de RAM (P2)

Como responsable del server, quiero que `monitoring` corra 24/7 pero acotado, para que observar prod no comprometa la RAM que prod necesita — el peak con staging activa ya deja margen fino (~2.3 GiB).

**Acceptance Scenarios**:
- **Given** el stack definido, **When** se suma su footprint "Normal" al presupuesto de RAM, **Then** el total baseline (staging apagada) queda en ~10.1 GiB y el peak (staging activa) en ~11.7 GiB — dentro de los 14 GiB, coincidiendo con la tabla de `docs/infrastructure-design.md`.
- **Given** los servicios de monitoring, **When** arrancan, **Then** todos tienen `restart: unless-stopped` (stack estable, no efímero) y viven en la red interna de Docker compartida, sin publicar puertos.
- **Given** Prometheus, **When** ingiere métricas, **Then** su retención es de 15 días (no infinita) para acotar el uso de disco/RAM a la cardinalidad baja de un single-tenant.

## Edge Cases

- **Grafana caído** → `grafana.miempresa.com` devuelve error de servicio de Traefik (router existe, backend down), no un crash del edge — mismo comportamiento que staging apagada.
- **Loki caído mientras corren contenedores** → los logs de ese período se pierden en Loki, pero los contenedores siguen corriendo normal (Promtail/Loki no son ruta crítica de prod); al volver Loki, Promtail reanuda desde su posición.
- **postgres-exporter-prod o Promtail con memory leak** → el `mem_limit` los mata por OOM (mueren y reinician por `unless-stopped`), no se comen la RAM del host; se detecta como reinicios en las métricas.
- **staging arranca/para** → su `postgres-exporter-staging` (ya en `docker-compose.staging.yml`, feature 005) nace/muere con staging; el stack `monitoring` **no** lo gestiona ni depende de él — Prometheus lo scrapea si está, lo marca `down` si no.
- **Server reiniciado** → el stack `monitoring` vuelve solo por `restart: unless-stopped`; los datos de Prometheus/Loki persisten en volúmenes con nombre (no se descartan como staging).

## Explicit Non-Goals

- **Exporter de Odoo** — no existe uno oficial mantenido; la observabilidad de Odoo se cubre por logs (Loki) + métricas de contenedor (cAdvisor) + el healthcheck HTTP existente. Agregar solo si se pide.
- **Alertmanager separado** — se usa Grafana Alerting directamente; no se despliega Prometheus Alertmanager.
- **Uptime Kuma u otra alternativa liviana** — descartada en el diseño a favor de Prometheus + Grafana.
- **Retención de largo plazo / storage remoto de métricas** (Thanos, Mimir, S3 para Loki) — retención local acotada es suficiente para single-tenant; fuera de alcance.
- **Dashboards de negocio / métricas de aplicación Odoo** (ventas, usuarios) — esto es observabilidad de infra, no BI.
- **Canal de alertas Telegram** — se eligió email; Telegram queda fuera salvo pedido explícito.
- **`postgres-exporter-staging`** — ya entregado en feature 005, no se re-especifica aquí; solo se lo scrapea oportunísticamente.
- **Aprovisionamiento de la política de Cloudflare Access como código** — se configura manualmente en el panel de Cloudflare (igual que el túnel y los hostnames del edge), documentado en INSTALL.md; el spec solo exige que Access esté delante de Grafana.

---
name: config-secrets-backup-metrics
code: SPEC-011
version: R00
date: 2026-07-14
status: Converged
---

# Spec: Config Secrets Out of Git + Backup Freshness as a Prometheus Metric

## Summary

Sacar `odoo.conf`/`odoo-staging.conf` de git (patrón `.example` + real gitignored en el server) con un chequeo automático que bloquea el arranque si `list_db`/`proxy_mode` no cumplen lo no-negociable, y exponer la freshness del backup como una métrica real de Prometheus vía textfile collector de node-exporter.

## User Stories

### US1 — Config real fuera de git, con red de seguridad al arrancar (P1)

Hoy `config/odoo.conf` y `config/odoo-staging.conf` están versionados en git. Cualquiera con acceso al repo ve (y puede tocar) la config real de producción, y un cambio manual en el server para un ajuste puntual queda atado a un commit. Se necesita el mismo patrón ya usado para `.env`: un `.example` versionado como referencia, y el archivo real gitignored y editable a mano en el server. Como red de seguridad mínima contra un `odoo.conf` mal editado a mano, Odoo debe rehusarse a arrancar si `list_db` no es `False` o `proxy_mode` no es `True`.

**Acceptance Scenarios**:
- **Given** un checkout nuevo del repo, **When** se lista `config/`, **Then** solo existen `odoo.conf.example` y `odoo-staging.conf.example` versionados; los `.conf` reales no aparecen en `git status` ni en el árbol del repo.
- **Given** `odoo.conf` real en el server con `list_db = False` y `proxy_mode = True`, **When** el contenedor arranca, **Then** Odoo levanta normalmente.
- **Given** `odoo.conf` real en el server editado a mano con `list_db = True` (o `proxy_mode = False`), **When** el contenedor arranca, **Then** el arranque falla con un mensaje que identifica cuál de los dos valores no cumple, y Odoo no queda escuchando tráfico.
- **Given** un server nuevo sin `odoo.conf`/`odoo-staging.conf` todavía creados, **When** se sigue el proceso de setup, **Then** copiar el `.example` correspondiente y completar los valores reales es suficiente para levantar el stack.

### US2 — Freshness del backup visible en Prometheus (P2)

El healthcheck de freshness del backup (`/backups/.last-success`, feature 009-backup-stable) hoy solo se puede ver vía `docker compose ps`/`docker inspect` — no dispara alertas ni aparece en Grafana. Se necesita esa misma información como una métrica de Prometheus, para poder graficarla y alertar si el backup diario no corrió.

**Acceptance Scenarios**:
- **Given** el backup corrió exitosamente, **When** Prometheus scrapea node-exporter, **Then** existe una métrica (timestamp o edad en segundos del último éxito) consultable en Prometheus/Grafana.
- **Given** el backup no corre por 2+ días (falla el systemd timer o el propio backup), **When** se consulta la métrica, **Then** su valor refleja la antigüedad real del último éxito (no se "congela" ni desaparece silenciosamente), permitiendo una alerta basada en umbral.
- **Given** el mecanismo elegido (textfile collector de node-exporter), **When** se agrega esta métrica, **Then** no se agrega ningún servicio/exporter nuevo al stack de `monitoring` — se reusa node-exporter ya corriendo.

## Edge Cases

- El chequeo de `list_db`/`proxy_mode` debe correr contra la config real efectiva de Odoo (post-merge de `odoo.conf` + cualquier override), no solo grepear el archivo, para no dar falsa seguridad si algo más pisa esos valores.
- Si `/backups/.last-success` nunca existió (server nuevo, backup nunca corrió con éxito), la métrica debe reflejar ese estado de forma distinguible de "backup viejo" (p.ej. ausencia de métrica o valor centinela), no un timestamp falso.
- El archivo `.prom` escrito por el textfile collector debe actualizarse atómicamente (write + rename) para que node-exporter nunca lea un archivo a medio escribir.

## Explicit Non-Goals

- No se migra ningún otro secreto o config además de `odoo.conf`/`odoo-staging.conf` (ej. `.env` ya sigue este patrón desde antes, fuera de alcance).
- No se agregan reglas de alerta en Prometheus/Alertmanager para la métrica de freshness — esta spec solo expone la métrica; alertar sobre ella queda para un backlog item aparte si se decide.
- No se valida ningún otro par de opciones de `odoo.conf` más allá de `list_db`/`proxy_mode` — son las únicas marcadas como no-negociables en la constitución.

## Clarifications

- El chequeo de `list_db`/`proxy_mode` corre en el entrypoint, antes de que Odoo arranque — si falla, el proceso termina y el contenedor nunca queda escuchando tráfico (no es un healthcheck post-arranque).

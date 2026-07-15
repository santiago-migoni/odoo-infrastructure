---
name: stack-layout-reorg
code: SPEC-013
version: R00
date: 2026-07-15
status: Converged
---

# Spec: Reorganización de layout por stack + imágenes Docker independientes

## Summary

Invertir el layout del repo de organización por tipo de artefacto (`config/`, `docker/`, `env/`) a organización por stack (`prod/`, `staging/`, `edge/`, `monitoring/`, `backup/`, cada uno autocontenido), como base para que cada stack tenga su propia imagen Docker independiente — hoy `prod` y `staging` comparten el mismo `Dockerfile`, lo que impide validar dependencias nuevas o un cambio de versión de Odoo en staging sin arriesgar el artefacto que corre en producción.

## User Stories

### US1 — Cada stack autocontenido en una sola carpeta (P1)

Hoy, para ver todo lo que define un stack (compose, Dockerfile, config, credenciales) hay que buscar en 3 carpetas de primer nivel distintas (`config/`, `docker/`, `env/`). Como operador, quiero abrir una sola carpeta por stack y ver ahí todo lo que le pertenece.

**Acceptance Scenarios**:
- **Given** el reorg aplicado, **When** se lista `prod/`, **Then** aparecen `docker/docker-compose.yml`, `docker/Dockerfile`, `docker/Dockerfile.tools`, `config/odoo.conf.example`, `env/.env.prod.example` — todo lo de prod, nada de otro stack.
- **Given** el reorg aplicado, **When** se lista la raíz del repo, **Then** no quedan `config/`, `docker/`, `env/` de primer nivel — cada uno se repartió dentro de su stack correspondiente.
- **Given** `scripts/`, `systemd/`, `addons/`, **When** se revisan tras el reorg, **Then** siguen en la raíz sin cambios (no pertenecen a un solo stack).

### US2 — `prod` y `staging` con imágenes Docker independientes (P1)

Como operador, quiero que `staging` tenga su propio `Dockerfile`, independiente del de `prod`, para poder validar una dependencia nueva, un addon, o un bump de versión de Odoo contra datos reales de staging sin tocar el artefacto que corre en producción.

**Acceptance Scenarios**:
- **Given** el reorg aplicado, **When** se compara `prod/docker/Dockerfile` con `staging/docker/Dockerfile`, **Then** son dos archivos independientes con contenido idéntico al del `Dockerfile` compartido de hoy (punto de partida idéntico, libres de divergir después).
- **Given** un cambio hecho solo en `staging/docker/Dockerfile`, **When** se ejecuta `rebuild-prod-odoo`, **Then** la imagen de prod no se ve afectada (sigue construyéndose desde `prod/docker/Dockerfile`, sin el cambio).
- **Given** que se quiere promover un cambio validado en staging hacia prod, **When** se sigue el proceso documentado, **Then** es un cambio de código explícito (editar `prod/docker/Dockerfile` a mano, en un commit/PR) — no hay ningún comando ni herramienta automática de sync.

### US3 — La herramienta de restore/refresh también independiente por stack (P2)

Hoy `docker/Dockerfile.backup` es una sola imagen de herramientas (restic+psql) usada por 3 flujos distintos (`backup` stack, `refresh-staging.sh`, `prod-db-restore.sh`). Como operador, quiero que cada flujo tenga su propia copia, para que un cambio en una no pueda acoplar o romper las otras.

**Acceptance Scenarios**:
- **Given** el reorg aplicado, **When** se listan `backup/docker/Dockerfile`, `staging/docker/Dockerfile.tools`, `prod/docker/Dockerfile.tools`, **Then** son 3 archivos independientes, con contenido idéntico entre sí al día uno (mismo punto de partida que `docker/Dockerfile.backup` tenía hoy).
- **Given** `refresh-staging.sh`, **When** se inspecciona qué Dockerfile construye para su imagen de herramientas, **Then** apunta a `staging/docker/Dockerfile.tools`, no a un archivo de otro stack.
- **Given** `prod-db-restore.sh`, **When** se inspecciona qué Dockerfile construye para su imagen de herramientas, **Then** apunta a `prod/docker/Dockerfile.tools`, no a un archivo de otro stack.

### US4 — Todo el tooling existente sigue funcionando tras el reorg (P1)

Como operador, no quiero que mover archivos rompa nada de lo que ya funciona: el dispatcher del Makefile, los timers de systemd, los scripts de tarea.

**Acceptance Scenarios**:
- **Given** el reorg aplicado, **When** se ejecuta `make help`/`make ps`/`make up-<stack>`/`make down-<stack>` para cada uno de los 5 stacks, **Then** funcionan igual que antes del reorg (mismo comportamiento, rutas internas actualizadas).
- **Given** el reorg aplicado, **When** se ejecutan `make run-backup`, `make refresh-staging`, `make restore-prod CONFIRM=yes`, `make nuke-staging`, **Then** funcionan igual que antes (los scripts subyacentes referencian las rutas nuevas).
- **Given** los `systemd` units (`odoo-backup.service`, `staging-refresh.service`), **When** se revisan sus `ExecStart=`, **Then** apuntan a las rutas correctas post-reorg.
- **Given** cualquier build de imagen (`Dockerfile`, `Dockerfile.tools`, o el de herramientas de `backup`), **When** se ejecuta, **Then** el build context sigue siendo la raíz del repo (necesario para copiar `addons/`), no la carpeta del stack — solo el flag `-f` apunta al `Dockerfile` en su nueva ubicación.

## Edge Cases

- Las redes/volúmenes Docker compartidos (`odoo-shared`, `staging-net`, `odoo-data`) no cambian — son recursos de Docker, no archivos del repo, no dependen de esta reorg.
- `backup/` no tiene subcarpeta `config/` — `backup.sh` se configura 100% por variables de entorno, no hay archivo de config que mover ahí.
- `edge/` y `monitoring/` no tienen `Dockerfile` propio en este spec — corren imágenes oficiales sin customización hoy.
- Los `.gitignore` de los archivos reales gitignored (`config/odoo.conf`, `config/odoo-staging.conf`, `env/.env.*`) se actualizan a las rutas nuevas (`prod/config/odoo.conf`, `staging/config/odoo-staging.conf`, `<stack>/env/.env.<stack>`) — los archivos reales en el server se mueven a mano siguiendo el mismo proceso de siempre (`cp .example` en la ubicación nueva), no hay migración automática de secretos.

## Explicit Non-Goals

- No se toca la lógica interna de ningún script (`backup.sh`, el contenido funcional de `refresh-staging.sh`/`nuke-staging.sh`/`prod-db-restore.sh`) — solo las rutas que referencian.
- No se crean `Dockerfile` para `edge`/`monitoring` — se crean el día que haga falta una feature real sobre esas imágenes oficiales, no en este spec.
- No se implementa ninguna herramienta de diff/sync asistida para promover cambios de `staging` a `prod` — la promoción es un PR de git explícito, usando el flujo que ya existe para todo el repo.
- No se arregla `scripts/next-feature-number.sh` (ya anotado en el backlog, B011).
- No se cambia el contenido de `Dockerfile`/`Dockerfile.tools` más allá del punto de partida idéntico al día uno — divergir el contenido de cada uno es trabajo futuro, no de este spec.

## Open Questions

Ninguna — todas las decisiones de diseño se cerraron en la sesión de `/grilling` previa a este spec, y la constitución ya fue enmendada (R07) para reflejarlas.

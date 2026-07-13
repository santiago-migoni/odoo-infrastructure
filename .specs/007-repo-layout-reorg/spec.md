---
name: repo-layout-reorg
code: SPEC-007
version: R00
date: 2026-07-13
status: Converged
---

# Spec: Reorganización de layout — `Docker/` y `env/`

## Summary

Reorganizar el repo agrupando los 5 `docker-compose.*.yml` y los 2 `Dockerfile*` bajo `Docker/`, y las 5 plantillas `.env.*.example` (más la convención de dónde vive el `.env.X` real de cada entorno) bajo `env/`, actualizando toda referencia existente (scripts, systemd, INSTALL.md, CLAUDE.md, docs) sin romper ningún stack ya entregado (001-006).

## Clarifications

### Session 2026-07-13

- Q: ¿El reorg a `env/` aplica solo a las plantillas versionadas o también a la convención real de dónde vive el `.env.X` de cada entorno? → A: Ambos — las plantillas y la convención real se mueven a `env/`. Cada `env_file:` de los compose files pasa a apuntar a `env/.env.X`, y el `cp` en `INSTALL.md` copia la plantilla directamente dentro de `env/`. El archivo real sigue gitignored (fuera de git), solo cambia la carpeta.

## User Stories

### US1 — Compose y Dockerfiles agrupados en `Docker/` (P1)

Como operador, quiero que los 5 `docker-compose.*.yml` y los 2 `Dockerfile*` vivan bajo `Docker/`, para que la raíz del repo no esté saturada de archivos de build/orquestación y sea fácil ubicarlos.

**Acceptance Scenarios**:
- **Given** el reorg aplicado, **When** se lista la raíz del repo, **Then** no queda ningún `docker-compose.*.yml` ni `Dockerfile*` a nivel raíz — todos están bajo `Docker/`.
- **Given** cualquier stack, **When** se corre `docker compose -f Docker/docker-compose.<stack>.yml up -d` desde la raíz del repo, **Then** funciona idéntico a antes (servicios healthy, sin romper builds, mounts relativos, ni `env_file`).
- **Given** `docker-compose.prod.yml` (build del servicio `odoo`) y `docker-compose.backup.yml` (build con `dockerfile: Dockerfile.backup`), **When** se construyen desde la nueva ubicación en `Docker/`, **Then** el build context sigue resolviendo a la raíz del repo (donde vive `addons/`), no a `Docker/` como contexto.

### US2 — Variables de entorno agrupadas en `env/` (P1)

Como operador, quiero que las plantillas `.env.*.example` y el `.env.X` real de cada entorno vivan bajo `env/`, para tener un único lugar donde buscar y gestionar secretos por entorno.

**Acceptance Scenarios**:
- **Given** el reorg aplicado, **When** se lista la raíz del repo, **Then** no queda ningún `.env.*.example` a nivel raíz — todos están bajo `env/`.
- **Given** cualquier `docker-compose.*.yml` en `Docker/`, **When** se inspecciona su directiva `env_file:`, **Then** apunta a `env/.env.<stack>` (path relativo resuelto correctamente desde `Docker/`).
- **Given** `INSTALL.md`, **When** se sigue el paso de completar credenciales, **Then** el comando es `cp env/.env.<stack>.example env/.env.<stack>` — el archivo real queda dentro de `env/`, y es exactamente el que el compose carga.
- **Given** el `.env.<stack>` real dentro de `env/`, **When** se revisa `.gitignore`, **Then** sigue excluido de git (solo cambió la carpeta, no la propiedad de "fuera del repo" versionado).

### US3 — Ninguna referencia rota al layout viejo (P1)

Como cualquiera que siga `INSTALL.md`, los scripts, o los timers de systemd, quiero que ningún comando o ruta quede apuntando al layout anterior, para no toparme con un comando que "funcionaba antes de mover los archivos".

**Acceptance Scenarios**:
- **Given** `INSTALL.md`, `scripts/*.sh`, `systemd/*.service`, `CLAUDE.md` y `docs/infrastructure-design.md`, **When** se buscan referencias a `docker-compose.*.yml`, `Dockerfile*` o `.env.*.example` a nivel raíz, **Then** no quedan coincidencias fuera de `.specs/` (ver Non-Goals sobre specs ya convergidos).
- **Given** cada `docker-compose.*.yml` movido a `Docker/`, **When** se revisan sus mounts relativos (`./config/...`), **Then** siguen resolviendo correctamente a `config/` en la raíz del repo (no se mueve `config/`).
- **Given** `systemd/odoo-backup.service` y `systemd/staging-teardown-boot.service`, **When** se inspecciona su `ExecStart`, **Then** referencia `Docker/docker-compose.<stack>.yml` y, si aplica, `env/.env.<stack>` — no la ruta vieja.

### US4 — Los 5 stacks siguen operables sin romper ninguna feature ya entregada (P1)

Como operador, quiero correr cada stack (prod, staging, edge, monitoring, backup) exactamente igual que antes del reorg — incluyendo `staging-up.sh`/`staging-down.sh`/`staging-extend.sh`, `setup-backup-role.sh`, `setup-monitoring-role.sh`, `restore-staging.sh`, y los timers de systemd — para no perder nada de lo entregado en las features 001-006.

**Acceptance Scenarios**:
- **Given** cada script en `scripts/*.sh` que invoca `docker compose -f docker-compose.<stack>.yml`, **When** se actualiza, **Then** apunta a `Docker/docker-compose.<stack>.yml` y sigue funcionando igual (verificado con el mismo tipo de smoke real usado en 005/006, no solo lectura de código).
- **Given** el build de la imagen de restore (`docker build -f Dockerfile.backup ...` en `staging-up.sh`), **When** se actualiza, **Then** referencia `Docker/Dockerfile.backup` con el contexto correcto (raíz del repo).

## Edge Cases

- **`docker-compose.override.yml`** (listado en `.gitignore`, sin archivo real hoy) → su entrada en `.gitignore` se actualiza a `Docker/docker-compose.override.yml` para mantener consistencia, aunque no exista un archivo real todavía.
- **Specs ya convergidos (001-006)** → sus `spec.md`/`plan.md`/`tasks.md` siguen mencionando rutas viejas (`docker-compose.prod.yml` a nivel raíz, etc.) — son historial congelado de decisiones ya tomadas y no se reescriben retroactivamente, igual que ningún spec convergido se edita después del hecho.
- **Submódulo `addons/`** → no se mueve ni se ve afectado; solo se referencia como build-context desde `Docker/Dockerfile`, con el contexto apuntando a la raíz del repo, no a `Docker/`.
- **CHANGELOG.md** → sus entradas históricas (versiones ya cortadas) no se reescriben; solo la entrada de esta feature bajo `[Unreleased]` describe el nuevo layout.

## Explicit Non-Goals

- **No se mueve `config/`** — sigue en la raíz; los compose files en `Docker/` referencian `../config/...`.
- **No se reescriben rutas dentro de specs ya convergidos** (`001-006`) — historial congelado.
- **No se implementa el Makefile** (roadmap B010) — esta reorg es previa e independiente, pero deja el terreno listo para cuando se construya (evita que B010 tenga que tocar paths dos veces).
- **No se renombran archivos** — `Dockerfile` sigue `Dockerfile`, `Dockerfile.backup` sigue `Dockerfile.backup`, cada `.env.<stack>.example` conserva su nombre — solo cambia la carpeta contenedora.
- **No se mueve `systemd/`** — los `.service`/`.timer` quedan donde están; solo se actualiza el `ExecStart` que apunta a las rutas nuevas.
- **No se toca `addons/`** (submódulo git separado).

## Open Questions

Ninguna — el alcance quedó resuelto en la sesión de clarificación.

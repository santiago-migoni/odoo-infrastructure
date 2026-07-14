---
name: staging-stable
code: TASKS-010
version: R00
date: 2026-07-14
---

# Tasks: Stack `staging` siempre-arriba con refresh semanal

## Phase 1: Contenedor siempre-arriba (US1)

- [x] T001 [US1] Modificar `docker/docker-compose.staging.yml`: agregar `restart: unless-stopped` a los 4 servicios (`db`, `pgbouncer`, `odoo-staging`, `postgres-exporter`)
- [x] T002 [P][US1] Eliminar `systemd/staging-teardown-boot.service` — `restart: unless-stopped` (T001) + la restauración nativa de Docker al boot ya cubren "staging vuelve sola tras un reinicio", sin unidad dedicada (mismo patrón que `prod`/`edge`/`backup`)

## Phase 2: Refresh semanal vía systemd (US2)

- [x] T003 [P][US2] Crear `systemd/staging-refresh.service`: `Type=oneshot`, `WorkingDirectory=/opt/odoo-infrastructure`, `ExecStart=/bin/sh /opt/odoo-infrastructure/scripts/staging-up.sh` (mismo patrón que `systemd/odoo-backup.service`)
- [x] T004 [P][US2] Crear `systemd/staging-refresh.timer`: `OnCalendar=weekly`, `Persistent=true`, `WantedBy=timers.target` (mismo patrón que `systemd/odoo-backup.timer`)
- [x] T005 [US2] Modificar `scripts/staging-up.sh`: eliminar la línea final `./scripts/staging-extend.sh` y el `echo` que la precede ("Armando teardown duro...") — el script ya no arma ningún teardown al terminar
- [x] T006 [US2] Eliminar `scripts/staging-extend.sh` — ya no hay sesión que extender
- [x] T007 [US2] Depende de T006 — Modificar `Makefile`: eliminar el target `staging-extend` (línea de receta, su entrada en `.PHONY`, y su mención en `help`)
- [x] T008 [US2] Modificar `scripts/staging-down.sh`: eliminar la línea `sudo systemctl stop odoo-staging-teardown.timer 2>/dev/null || true` — el mecanismo de timer transiente ya no existe

## Phase 3: Documentación

- [x] T009 [P] Actualizar `INSTALL.md` (paso 6, Stack `staging`): quitar la sección de uso de `staging-extend.sh` y la instalación de `staging-teardown-boot.service`; agregar la instalación de `staging-refresh.service`/`.timer` (mismo patrón que el paso 5 de backup); actualizar el encabezado/intro (ya no "efímero... auto-teardown a las ~3h"); en la sección de Desarme, reemplazar las líneas que referencian `staging-teardown-boot.service`/`odoo-staging-teardown.timer` por deshabilitar `staging-refresh.timer`
- [x] T010 [P] Actualizar `CLAUDE.md`: corregir el comentario de `make staging-up` ("restore last prod backup + anonymize + up (max 3h, then auto down -v)" → sin la parte de auto-teardown) y la frase "Staging auto-tears down after ~3h (`down -v`)" en la sección Staging
- [x] T011 [P] Actualizar `docs/infrastructure-design.md`: las 4 filas de RAM de staging (Odoo staging, Postgres staging, PgBouncer staging, postgres-exporter-staging) — nota de "Efímera: solo pesa en el peak" a "siempre-arriba, footprint Normal permanente"; reestructurar la tabla de escenarios totales — el escenario que antes era "peak (staging activa, ventana ~3h)" pasa a ser el estado Normal por defecto, "staging apagada" pasa a ser el escenario de pausa manual (no el default)

## Verification

- [x] VERIFY US1 — **Confirmado real**: los 4 servicios de `staging` levantados (`db`, `pgbouncer`, `postgres-exporter` healthy; `odoo-staging` corriendo, `unhealthy` solo porque no se corrió el restore real en este smoke — esperado, no afecta lo verificado). `docker restart` manual sobre los 4 contenedores → los 4 volvieron solos, `RestartCount=0` en todos (sin loop). `systemd/staging-teardown-boot.service` confirmado ausente del repo (`ls` → No such file). Nota de migración (`systemctl disable --now staging-teardown-boot.service` antes de actualizar un deploy real) ya documentada en `INSTALL.md` (T009).
- [x] VERIFY US2 — **Confirmado con smoke real de punta a punta**: backup real creado (stub `db` con schema mínimo de las 7 tablas que toca `anonymize-staging.sql` + filestore real) → `staging-up.sh` corrido completo, `exit 0`, terminó en "OK — staging arriba" sin ningún intento de invocar `staging-extend.sh` (eliminado limpio del flujo, confirmado en el log completo). Anonimización confirmada real en los 3 chequeos (`ir_mail_server` activos: 0, emails reales: 0, payment providers habilitados: 0). `staging-down.sh` corrido después, `exit 0`, `down -v` destruyó los volúmenes sin fallar en la línea eliminada. Revisión manual de sintaxis INI de `staging-refresh.service`/`.timer` sin hallazgos (`systemd-analyze` no disponible en este sandbox macOS, mismo criterio que 003/005/009 — ejecución real del timer reservada a deploy).
- [x] VERIFY US3 — **Confirmado con smoke real**: staging levantada con datos anonimizados frescos (marcador real: `count=1` en `ir_mail_server`); `docker compose stop` sobre el stack completo → los 4 contenedores `Exited`, volúmenes (`db-data-staging`, `odoo-data-staging`) confirmados intactos; `docker compose up -d` posterior recuperó el mismo dato (`count=1`, mismo registro) sin recorrer restore+anonimización — ningún log de restic ni de `anonymize-staging.sql` en este segundo `up`. `staging-down.sh` ya confirmado en VERIFY US2 como `down -v` (destructivo) sin cambios de comportamiento.
- [x] VERIFY Conflicto de constitución señalado en `plan.md` queda intacto — confirmado `.specs/constitution.md` sigue en `R04`, sin tocar; la enmienda queda pendiente para `spec-flow:converge`, como decidió el plan.
- [x] VERIFY No se crearon archivos fuera de los listados en "File Structure" de `plan.md` — confirmado con `git status`: coincide exactamente (2 eliminados, 2 nuevos, 6 modificados + `.specs/010-staging-stable/`).
- [x] VERIFY Sin dependencias nuevas — confirmado: `restore-staging.sh`/`anonymize-staging.sql` sin tocar, mismas imágenes ya en uso.

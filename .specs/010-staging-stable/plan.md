---
name: staging-stable
code: PLAN-010
version: R00
date: 2026-07-14
---

# Plan: Stack `staging` siempre-arriba con refresh semanal

## Approach

`docker-compose.staging.yml` gana `restart: unless-stopped` en sus 4 servicios — esto solo, sin ninguna unidad nueva de systemd, ya hace que staging sobreviva un reinicio del server (mismo mecanismo, sin unidad dedicada, que ya usan `prod`/`edge`/`backup`). El teardown al boot (`staging-teardown-boot.service`) se **elimina** (no se invierte a una unidad positiva — ya no hace falta, Docker restaura los contenedores solo). El refresh semanal es un systemd timer nuevo (`staging-refresh.service`/`.timer`, mismo patrón que `odoo-backup.service`/`.timer` de 009) que dispara `staging-up.sh` — el script real no cambia su lógica de restore/anonimización, solo pierde la línea final que armaba el teardown de 3h. `staging-extend.sh` y toda referencia a él (Makefile, `staging-down.sh`) se eliminan.

## Constitution Check

- **Tech stack / Code principles (R04)**: "Todo scheduling recurrente usa systemd timers, nunca un scheduler embebido" → el refresh semanal usa systemd, mismo mecanismo que backup (009). ✓
- **"Staging es una réplica fiel de prod a menor escala"** → sin cambios, el modelo multiproceso/longpolling sigue igual. ✓
- **"Staging es efímera... No hay staging 'siempre arriba'"** → este principio se **reemplaza** por el diseño resuelto en la sesión de `/grilling` (backlog B011); es la propia constitución la que necesita una enmienda posterior a converger esta feature (no antes — el patrón ya usado en 009/R04 fue amendar *antes* de specificar porque el conflicto era evidente de entrada; acá, dado que **ya está resuelto y aceptado explícitamente por el usuario**, la enmienda se registra al converger, mismo criterio que "la constitución documenta lo que es cierto", no lo que podría llegar a serlo).
- **"RAM es el recurso más restrictivo... cualquier cambio de sizing debe revisarse contra el presupuesto"** → revisado explícitamente en `/grilling` (margen permanente ~1.9–2.3 GiB, aceptado dentro de los 14 GiB actuales); se documenta en `docs/infrastructure-design.md` como parte de esta feature. ✓
- Un conflicto detectado (el de "Staging es efímera") — resuelto con enmienda al converger, no bloqueante para planificar/implementar.

## Architecture

```text
Antes:                                          Después:
make staging-up                                 make staging-up  — SIN CAMBIOS en su lógica interna
  └─ staging-up.sh                                 └─ staging-up.sh
       ...restore, anonimización...                     ...restore, anonimización... (sin cambios)
       up -d pgbouncer odoo-staging postgres-exp        up -d pgbouncer odoo-staging postgres-exporter
       staging-extend.sh  ◀── arma teardown 3h          (fin — ya no arma ningún teardown)

systemd/staging-teardown-boot.service           systemd/staging-teardown-boot.service
  (down -v incondicional en cada boot)            ◀── ELIMINADO

(sin timer de refresh)                          systemd/staging-refresh.service + .timer  ◀── NUEVO
                                                    OnCalendar=weekly → ExecStart: staging-up.sh
                                                    (mismo patrón que odoo-backup.service/.timer de 009)

docker-compose.staging.yml: sin restart policy  docker-compose.staging.yml: + restart: unless-stopped
                                                    en los 4 servicios (db, pgbouncer, odoo-staging,
                                                    postgres-exporter) — Docker los restaura solo tras
                                                    un reinicio del server, sin unidad systemd dedicada
                                                    (mismo mecanismo que prod/edge/backup)

scripts/staging-extend.sh                       ELIMINADO — ya no hay sesión que "extender"
Makefile: staging-extend                        ELIMINADO (target + .PHONY + mención en help)
scripts/staging-down.sh:                        limpia la línea muerta que paraba el timer
  systemctl stop odoo-staging-teardown.timer      transiente (ya no existe ese mecanismo)
```

- **Por qué eliminar en vez de invertir el boot-teardown**: `restart: unless-stopped` + la restauración nativa de Docker al arrancar el daemon ya resuelve "staging vuelve sola tras un reinicio" sin necesidad de una unidad systemd dedicada — es exactamente el mismo mecanismo (cero unidades "keep-alive") que ya usan `prod`, `edge` y `backup` (009). Escribir una unidad positiva nueva sería reimplementar algo que Docker ya hace.
- **`staging-refresh.service`/`.timer`**: mismo patrón exacto que `odoo-backup.service`/`.timer` (`Type=oneshot`, `OnCalendar=weekly` — sin hora específica, mismo nivel de simplicidad que `OnCalendar=daily` del backup, que tampoco fija una hora custom). `ExecStart` corre `./scripts/staging-up.sh` (no `docker compose exec`, porque a diferencia de backup el contenedor no es un proceso único siempre-listo para `exec` — es un script host que orquesta el ciclo completo restore→anonimización→up de varios contenedores).
- **`staging-up.sh` como única fuente de refresh**: el timer semanal y `make staging-up`/`staging-db-restore` (manual) invocan exactamente el mismo comando — no hay una rama de código "automática" separada de la "manual" (US2/AC4 del spec).
- **RAM**: sin cambios de `mem_limit`/`shared_buffers`/workers — lo que cambia es que el footprint Normal de staging (~1.6 GiB, ya documentado por servicio) pasa a ser parte del baseline permanente en vez de un escenario de "peak, ventana de 3h". Se documenta en `docs/infrastructure-design.md` (tabla por servicio + reestructuración de la tabla de escenarios totales, ver File Structure).

## File Structure

```text
odoo-infrastructure/
├── docker/docker-compose.staging.yml   ← modificado: + `restart: unless-stopped` en los 4 servicios (db, pgbouncer, odoo-staging, postgres-exporter)
├── scripts/
│   ├── staging-up.sh                   ← modificado: elimina la línea final `./scripts/staging-extend.sh` (ya no arma teardown)
│   ├── staging-down.sh                 ← modificado: elimina la línea `sudo systemctl stop odoo-staging-teardown.timer` (mecanismo de timer transiente ya no existe)
│   └── staging-extend.sh               ← ELIMINADO
├── systemd/
│   ├── staging-teardown-boot.service   ← ELIMINADO
│   ├── staging-refresh.service         ← nuevo. Type=oneshot, WorkingDirectory=/opt/odoo-infrastructure, ExecStart=./scripts/staging-up.sh (mismo patrón que odoo-backup.service)
│   └── staging-refresh.timer           ← nuevo. OnCalendar=weekly, Persistent=true, WantedBy=timers.target (mismo patrón que odoo-backup.timer)
├── Makefile                            ← modificado: elimina el target `staging-extend` (+ su entrada en `.PHONY` y en `help`)
├── INSTALL.md                          ← modificado (paso 6): quita la sección de `staging-extend.sh` y la instalación de `staging-teardown-boot.service`; agrega la instalación de `staging-refresh.service`/`.timer`; actualiza el encabezado/intro (ya no "efímero... auto-teardown"); actualiza la sección de Desarme (quita las líneas que referencian `staging-teardown-boot.service`/`odoo-staging-teardown.timer`, agrega deshabilitar `staging-refresh.timer`)
├── CLAUDE.md                           ← modificado: corrige los 2 comentarios stale ("max 3h, then auto down -v" en `make staging-up`; "Staging auto-tears down after ~3h" en la sección Staging)
└── docs/infrastructure-design.md       ← modificado: las 4 filas de RAM de staging (Odoo/Postgres/PgBouncer/postgres-exporter staging) pasan de "Efímera: solo pesa en el peak" a "siempre-arriba"; la tabla de escenarios totales se reestructura — el escenario "peak (staging activa, ventana ~3h)" pasa a ser el estado Normal permanente, "staging apagada" pasa a ser el escenario de pausa manual (no el default)
```

`config/odoo-staging.conf`, `config/traefik-dynamic.yml`, `scripts/restore-staging.sh`, `scripts/anonymize-staging.sql` — sin cambios (Non-Goals del spec: mecanismo de restore/anonimización y ruteo intactos).

## Data Model

N/A — sin modelo de datos propio.

## API / Interface Contracts

- **`make staging-up`** — sin cambios de interfaz, mismo comando, mismo resultado (ya no arma un teardown al final).
- **`make staging-down`** — sin cambios de interfaz (`down -v`, destructivo).
- **`make staging-extend`** — **eliminado**, ya no existe.
- **Refresh automático**: sin comando nuevo expuesto al operador — el timer `staging-refresh.timer` lo dispara solo, ejecutando el mismo `staging-up.sh`.
- **Boot**: sin comando — `restart: unless-stopped` es responsabilidad de Docker, no de un target.

## Dependencies

Ninguna — reusa `staging-up.sh`/`restore-staging.sh`/`anonymize-staging.sql` sin cambios de lógica, y el patrón de systemd timer ya usado en 009.

## Risks & Unknowns

- **`staging-refresh.timer` semanal disparándose sobre una sesión de QA en curso** — comportamiento aceptado explícitamente (ver spec Edge Cases): cualquier refresh es un reset completo. Sin mitigación de código; la cadencia semanal (no diaria) es la mitigación de diseño ya decidida.
- **Orden de eliminación de `staging-teardown-boot.service`**: si en algún server real ya está instalado (`systemctl enable`d) y no se deshabilita explícitamente antes de borrar el archivo del repo, quedaría una unidad fantasma corriendo con el comportamiento viejo (destruir staging en cada boot) — la sección de `implement`/INSTALL.md debe documentar `systemctl disable --now staging-teardown-boot.service` como paso de migración, no solo borrar el archivo del repo. Ninguna verificación automática puede confirmar esto sin acceso real a `serverdipleg` — queda como paso operativo documentado, mismo criterio que la instalación de cualquier unidad systemd en este proyecto (reservado a deploy real).
- **`restart: unless-stopped` en los 4 servicios de staging**: mismo riesgo ya mitigado en 009 (loop de reinicio) — pero acá no aplica el mismo peligro porque ningún servicio de staging tiene un `entrypoint` que "termina y se reinicia" (son procesos long-running normales: Postgres, PgBouncer, Odoo, el exporter) — no hace falta ningún override de entrypoint como en backup. Verificar en `implement` igual, con smoke real, que los 4 contenedores quedan estables tras un `docker restart` manual de cada uno.
- **Reestructuración de la tabla de escenarios de RAM** en `docs/infrastructure-design.md`: los números nuevos se derivan sumando el "Normal" ya publicado por servicio (staging ≈ 1.6 GiB), no se inventan — pero la explicación narrativa existente bajo la tabla (que ya tenía una derivación no del todo reconciliable, señalado en 009) no se toca más allá de lo estrictamente necesario para que la tabla de escenarios sea consistente con el nuevo estado por defecto.

# odoo-infrastructure

Infraestructura self-hosted para una instancia Odoo 19 Community de un solo cliente (single-tenant), on-premise sobre Docker Compose. Basada en los principios de [oec.sh](https://oec.sh) (self-hosted, "bring your own cloud"): reverse proxy sin exponer puertos, backups cifrados con retención GFS, monitoring propio, y despliegue reproducible sin depender de servicios gestionados de cloud.

## Arquitectura

5 stacks de Docker Compose independientes, todos en una misma red interna de Docker — **ningún contenedor publica puertos al host**. Cada stack es autocontenido en su propia carpeta de primer nivel (`<stack>/docker/`, `<stack>/config/`, `<stack>/env/`), no agrupado por tipo de artefacto:

| Stack | Archivo | Servicios |
|---|---|---|
| `prod` | `prod/docker/docker-compose.yml` | `odoo`, `db`, `pgbouncer` |
| `staging` | `staging/docker/docker-compose.yml` | `odoo`, `db`, `pgbouncer`, `postgres-exporter` |
| `edge` | `edge/docker/docker-compose.yml` | `traefik`, `cloudflared` |
| `monitoring` | `monitoring/docker/docker-compose.yml` | `prometheus`, `grafana`, `loki`, `promtail`, `cadvisor`, `node-exporter`, `postgres-exporter-prod` |
| `backup` | `backup/docker/docker-compose.yml` | `backup` (siempre-arriba, disparado por systemd timer) |

**Tráfico:** Internet → Cloudflare Edge (TLS) → `cloudflared` → Traefik (ruteo por hostname, sin puertos publicados) → Odoo.

**Staging** replica el modelo operativo de prod a menor escala (mismo modelo multiproceso, sin `dev_mode`, mismos datos reales anonimizados) pero corre su propia imagen — `prod`/`staging` tienen `Dockerfile` independientes, nunca compartidos, para poder validar dependencias/addons/una versión nueva de Odoo contra datos reales sin arriesgar el artefacto de producción. Siempre-arriba, se refresca automáticamente una vez por semana restaurando el último backup de prod y anonimizándolo antes de levantar Odoo.

**Backups** (DB + filestore juntos, nunca uno sin el otro) van cifrados a Cloudflare R2 con retención GFS (30 diarios / 3 meses semanales / 1 año mensual) más una copia local de 7 días, disparados por systemd timer.

## Principios de diseño

- `list_db=False` y `proxy_mode=True` son no negociables en cualquier `odoo.conf` expuesto — verificado automáticamente al arrancar el contenedor, no solo documentado.
- Nunca se usa el tag `latest` de ninguna imagen — siempre versión mayor fija + build fechado.
- Deploys a producción son siempre manuales con aprobación; a staging son automáticos tras lint + tests.
- Todo scheduling recurrente usa systemd timers, nunca un scheduler embebido en un contenedor.
- El `Makefile` en la raíz es la única interfaz operativa — compartida entre uso manual y CI, sin lógica de deploy duplicada.
- RAM es el recurso más restrictivo del servidor — cualquier cambio de sizing se revisa contra el presupuesto documentado.

Detalle completo en la [constitución del proyecto](.specs/constitution.md).

## Empezar

Instalación paso a paso, de punta a punta (clonar un release taggeado, build de la imagen, y levantar cada stack): [INSTALL.md](INSTALL.md).

## Operación diaria

```bash
make help                     # ayuda de dos secciones: STACKS + TAREAS
make up-prod                  # levantar producción
make logs-prod-odoo           # logs en vivo
make refresh-staging          # refresh manual de staging (restore + anonimización)
make run-backup                # correr un backup ahora
make restore-prod CONFIRM=yes   # disaster recovery — destructivo, requiere confirmación explícita
```

Convención de targets: `<verbo>-<stack>[-<servicio>]` (verbo primero, servicio opcional siempre al final). Tipeá un verbo solo (`make down`) para ver qué combinaciones acepta — ningún comando termina en un error mudo de `make`.

## Desarrollo

Este repo se desarrolla con spec-flow (spec-driven development): cada feature vive en `.specs/NNN-nombre-feature/` con su ciclo `spec → plan → tasks → implement → converge`. Ideas y trabajo futuro sin especificar todavía viven en [.specs/backlog.md](.specs/backlog.md).

Lint y tests corren sobre el submódulo de addons custom (`addons/`), no sobre este repo:

```bash
black --check addons/ && isort --check addons/ && flake8 addons/ && pylint-odoo addons/
```

## Documentación

- [Constitución del proyecto](.specs/constitution.md)
- [Historial de diseño por feature](.specs/archive/) — cada `NNN-nombre/` archivado tiene su `spec.md`/`plan.md`/`tasks.md` con el razonamiento detrás de cada decisión
- [Instalación paso a paso](INSTALL.md)
- [Historial de versiones](CHANGELOG.md)
- [Roadmap / trabajo pendiente](.specs/backlog.md)

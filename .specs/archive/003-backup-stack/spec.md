---
name: backup-stack
code: SPEC-003
version: R00
date: 2026-07-11
status: Converged
---

# Spec: Stack `backup` (contenedor efímero)

## Summary

Construir el stack `docker-compose.backup.yml` (contenedor efímero, un solo servicio) que respalda DB + filestore de producción juntos, los cifra, y los sube a Cloudflare R2 con retención GFS, manteniendo además una copia local de los últimos 7 días — disparado diariamente por un timer de systemd versionado en el repo.

## User Stories

### US1 — Backup completo y reproducible (P1)

Como operador, quiero que cada corrida de backup genere un `pg_dump` de la base y un `tar.gz` del filestore juntos, usando un usuario de Postgres dedicado de solo lectura (no las credenciales completas de Odoo), para que un restore nunca quede incompleto y el contenedor de backup no tenga permisos de escritura sobre la base.

**Acceptance Scenarios**:
- **Given** el stack `prod` corriendo, **When** se ejecuta `docker compose run --rm backup`, **Then** se genera un `pg_dump -Fc` de la base `odoo` (conectando con un rol de Postgres dedicado, permisos `SELECT` únicamente) y un `tar.gz` del volumen de filestore, ambos con el mismo timestamp/nombre de corrida.
- **Given** que el `pg_dump` falla, **When** el contenedor termina, **Then** no se sube nada a ningún destino (ni local ni R2) — un backup parcial nunca se guarda como si fuera válido.

### US2 — Cifrado antes de subir (P1)

Como operador, quiero que el backup se cifre con GPG (simétrico, passphrase) antes de tocar cualquier destino remoto, para que un backup filtrado o interceptado no sea legible sin la passphrase.

**Acceptance Scenarios**:
- **Given** el dump + tar generados, **When** se preparan para subir, **Then** ambos quedan cifrados con `gpg --symmetric --cipher-algo AES256` usando una passphrase provista vía `.env.backup` — nunca se sube ni se guarda localmente el archivo sin cifrar.

### US3 — Destinos: copia local + R2 con retención GFS (P1)

Como operador, quiero que el backup cifrado se guarde localmente (últimos 7 días) y se suba a Cloudflare R2 con retención GFS (diarios 30 días, semanales 3 meses, mensuales 1 año) — con la lógica de qué corrida es diaria/semanal/mensual y la poda de vencidos manejada por el propio script (no por lifecycle rules configuradas en el bucket) —, para tener restore rápido sin depender de internet y a la vez cobertura ante un desastre físico del servidor.

**Acceptance Scenarios**:
- **Given** un backup cifrado generado, **When** termina la corrida, **Then** queda una copia en un bind mount a una ruta del filesystem del servidor (ej. `/srv/odoo-backups`, accesible con herramientas normales del SO ante una emergencia) y se sube vía `rclone` a `daily/` en el destino configurado (R2 en producción real; un backend de prueba en esta feature, ver Clarifications); si corresponde (ej. domingo, día 1 del mes), se copia también a `weekly/`/`monthly/`.
- **Given** backups en `daily/`/`weekly/`/`monthly/` más viejos que su ventana de retención, **When** corre una nueva backup, **Then** el script los borra del destino remoto (no solo de la copia local).
- **Given** copias locales de más de 7 días, **When** corre una nueva backup, **Then** las copias locales vencidas se eliminan (no crecen indefinidamente).

### US4 — Disparo automático diario (P2)

Como operador, quiero que el backup corra solo, todos los días, sin que yo tenga que acordarme de ejecutarlo a mano.

**Acceptance Scenarios**:
- **Given** los unit files `systemd` de este repo instalados en el servidor, **When** llega la hora programada, **Then** se dispara `docker compose run --rm backup` automáticamente, una vez por día.

### US5 — Contenedor efímero, sizing acotado (P2)

Como operador, quiero que el contenedor de backup no quede corriendo entre ejecuciones y tenga límites de recursos, para que no compita por RAM con el resto de los stacks fuera de su ventana de ejecución (minutos, no permanente).

**Acceptance Scenarios**:
- **Given** el stack `backup`, **When** se inspecciona `docker-compose.backup.yml`, **Then** el servicio no tiene `restart:` (corre y termina, vía `run --rm`) y tiene `mem_limit`/`cpus` definidos.

## Edge Cases

- El backup corre mientras `prod` está caído (sin `db` disponible) → debe fallar visiblemente (log claro, exit code distinto de 0), no producir un backup vacío/corrupto.
- Falla la subida a R2 (o al backend de prueba) después de generar el backup local → la copia local válida no se borra; el fallo de subida queda logueado como tal, distinto de un fallo de generación del dump.
- El disco local se queda sin espacio para la copia de 7 días → falla visiblemente, no corrompe silenciosamente un backup a medio escribir.

## Explicit Non-Goals

- Creación real del bucket R2 y sus credenciales — paso manual del operador, fuera de este repo (mismo patrón que el Tunnel de Cloudflare en la feature `edge`).
- Generación/gestión de la passphrase GPG real — se referencia vía `.env.backup`, el valor real lo define el operador.
- Restore automatizado (consumir estos backups) — corresponde a la feature `staging` (ahora reordenada como feature 4), que restaura contra lo que esta feature produce.
- Makefile — feature separada (última del roadmap); el timer de `systemd` invoca `docker compose run --rm backup` directo.
- Monitoreo/alertas sobre fallos de backup — corresponde a la feature `monitoring`.

## Clarifications

### Session 2026-07-11

- Q: ¿El backup usa las credenciales de `.env.prod`, o un usuario de Postgres dedicado de solo lectura? → A: Usuario dedicado, solo lectura (`SELECT` únicamente) — mismo principio de blast-radius que separar `.env.prod`/`.env.edge`. Requiere un pequeño ajuste en `db` (feature 1) para crear ese rol.
- Q: ¿Cómo accede el backup al volumen de filestore (`odoo-data`), hoy project-scoped en `docker-compose.prod.yml`? → A: Se hace externo (`docker volume create odoo-data`), mismo patrón que la red `odoo-shared` de la feature `edge`. Backup lo monta `:ro`. Requiere un ajuste equivalente en `docker-compose.prod.yml` (volumen externo en vez de project-scoped).
- Q: ¿Quién decide qué backup es diario/semanal/mensual y quién poda los vencidos — lifecycle rules del bucket R2, o el script propio? → A: El script propio maneja las 3 carpetas (`daily/`/`weekly/`/`monthly/`) y su poda — toda la lógica de retención queda versionada y testeable localmente, sin depender de config manual en el dashboard de R2.
- Q: ¿La copia local vive en un volumen de Docker con nombre o en un bind mount a una ruta del host? → A: Bind mount a una ruta del filesystem del servidor (ej. `/srv/odoo-backups`) — accesible con herramientas normales del SO en una emergencia, sin depender de comandos de Docker.

- **Alcance R2**: solo config (rclone apuntando a variables de entorno vía `.env.backup`) — la creación real del bucket/credenciales queda para después, mismo patrón que `TUNNEL_TOKEN` en la feature `edge`.
- **Cifrado**: GPG simétrico con passphrase (no par de claves asimétrico) — más simple de operar para un solo operador/servidor.
- **Testing sin R2 real**: se prueba contra un backend de `rclone` local (o un servidor S3-compatible tipo MinIO en un contenedor de prueba), no contra Cloudflare real. El backend R2 real se swapea después cambiando solo la config de `rclone`.
- **Disparo (`systemd`)**: unit files `.service`/`.timer` versionados en el repo, listos para instalar — no queda como paso puramente manual/no versionado.

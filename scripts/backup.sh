#!/bin/sh
set -e

# Este backup es single-writer: el timer de systemd corre una sola vez por vez.
# Por eso `restic unlock --remove-all` antes de cada operación es seguro y
# necesario: un lock previo siempre es de una corrida muerta (kill sucio, OOM),
# y `restic unlock` a secas NO borra locks de otra hostname — y cada contenedor
# tiene la suya (su container ID), así que un lock huérfano bloquearía todos los
# backups siguientes. `--remove-all` los limpia sin importar la hostname.

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Nombre estable (no timestamped): restic ya fecha cada snapshot, y un path
# estable maximiza el dedupe (tablas sin cambios = mismos bloques).
DUMP_FILE="$WORKDIR/db.sql"
FILESTORE_DIR="/filestore/.local/share/Odoo/filestore/odoo"

echo "[backup] Volcando base de datos (pg_dump -Fp)..."
# --no-privileges: excluye los GRANT sobre backup_readonly (rol que solo
# existe en prod) — sin esto, restaurar el dump en cualquier otro lado
# (staging, un disaster-recovery a un server nuevo) corta con "role
# backup_readonly does not exist" en cuanto psql llega a esas líneas.
pg_dump -Fp --no-privileges -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -f "$DUMP_FILE"

# --- Repo local: única lectura/chunkeo del filestore ---
export RESTIC_REPOSITORY="$RESTIC_REPOSITORY_LOCAL"
echo "[backup] Repo local ($RESTIC_REPOSITORY)..."
restic cat config >/dev/null 2>&1 || restic init
restic unlock --remove-all
restic backup "$DUMP_FILE" "$FILESTORE_DIR"
restic forget --keep-daily 14 --prune

# --- Repo R2: se puebla copiando el snapshot ya chunkeado, sin releer el filestore ---
# Si R2 falla, el snapshot local de arriba ya está completo.
export RESTIC_REPOSITORY="$RESTIC_REPOSITORY_R2"
export RESTIC_FROM_PASSWORD="$RESTIC_PASSWORD"
echo "[backup] Repo R2 ($RESTIC_REPOSITORY)..."
restic cat config >/dev/null 2>&1 || restic init
restic unlock --remove-all
restic copy --from-repo "$RESTIC_REPOSITORY_LOCAL" latest
restic forget --keep-daily 14 --keep-weekly 4 --keep-monthly 12 --keep-yearly 3 --prune

# Marcador de salud: solo se toca acá, tras el último paso que puede fallar —
# si algo anterior corta el script (set -e), el healthcheck sigue viendo el
# timestamp de la última corrida realmente exitosa, no una falsa señal de éxito.
touch /backups/.last-success

# Métrica para node-exporter (textfile collector): mismo principio que el
# marcador de arriba, solo se escribe tras el éxito completo. Se escribe a un
# temp file en el mismo directorio y se mueve (rename atómico) para que
# node-exporter nunca lea un .prom a medio escribir.
if [ -d /textfile-collector ]; then
  echo "odoo_backup_last_success_timestamp_seconds $(date +%s)" > /textfile-collector/odoo_backup.prom.tmp
  mv /textfile-collector/odoo_backup.prom.tmp /textfile-collector/odoo_backup.prom
fi

echo "[backup] OK"

#!/bin/sh
# Restaura DB + filestore del último backup de prod (repo restic LOCAL,
# nunca R2) hacia staging. Corre dentro de la imagen docker/Dockerfile.backup
# (ya trae restic + cliente pg) vía --entrypoint, ver scripts/staging-up.sh.
#
# El dump se carga directo contra db:5432, nunca por pgbouncer:6432 — el
# transaction pooling rompe una carga de dump grande a nivel de sesión.
#
# El filestore se renombra de odoo/ a odoo_staging/ al copiarlo: staging usa
# un db_name distinto y Odoo busca el filestore bajo ese nombre exacto.
set -e

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

export RESTIC_REPOSITORY="$RESTIC_REPOSITORY_LOCAL"

echo "[restore-staging] Restaurando el último snapshot..."
# --no-lock: el repo se monta :ro (staging nunca debe poder escribir en los
# backups de prod) y restic necesita tomar un lock incluso para restaurar —
# sin --no-lock, reintenta escribir el lock contra un filesystem de solo
# lectura indefinidamente.
restic restore latest --no-lock --target "$WORKDIR"

DUMP_FILE=$(find "$WORKDIR" -name db.sql | head -1)
[ -n "$DUMP_FILE" ] || { echo "[restore-staging] no se encontró db.sql en el snapshot" >&2; exit 1; }

echo "[restore-staging] Cargando dump en odoo_staging (directo a db:5432, no pgbouncer)..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h db -p 5432 -U "$POSTGRES_USER" -d odoo_staging \
  -v ON_ERROR_STOP=1 -f "$DUMP_FILE"

echo "[restore-staging] Copiando filestore (odoo/ -> odoo_staging/)..."
FILESTORE_SRC=$(find "$WORKDIR" -type d -path '*/filestore/odoo' | head -1)
[ -n "$FILESTORE_SRC" ] || { echo "[restore-staging] no se encontró el filestore en el snapshot" >&2; exit 1; }
mkdir -p /staging-data/.local/share/Odoo/filestore/odoo_staging
cp -r "$FILESTORE_SRC/." /staging-data/.local/share/Odoo/filestore/odoo_staging/

# Este contenedor corre como root — sin este chown, Odoo (UID 100/GID 101,
# nunca root) no puede ni crear .local/share/Odoo/sessions/ dentro del mismo
# volumen (falla con PermissionError apenas arranca, confirmado en test real).
chown -R 100:101 /staging-data

echo "[restore-staging] OK"

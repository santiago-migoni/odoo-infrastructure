#!/bin/sh
# Restaura DB + filestore de un backup de prod hacia la propia prod (disaster
# recovery). Corre dentro de la imagen prod/docker/Dockerfile.tools (ya trae
# restic + cliente pg) vía --entrypoint, ver scripts/prod-db-restore.sh.
#
# A diferencia de restore-staging.sh: RESTIC_REPOSITORY ya viene seteada por
# el orquestador (R2 por defecto, o local si LOCAL=yes) — este script no la
# elige. El db_name es el mismo (odoo), sin rename de filestore. Y la DB de
# prod ya tiene datos (no arranca vacía como staging), así que hace falta
# recrearla antes de cargar el dump: un pg_dump -Fp es SQL plano, cargarlo
# sobre una base con objetos existentes falla.
set -e

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

echo "[restore-prod] Restaurando el último snapshot ($RESTIC_REPOSITORY)..."
# --no-lock: el repo se monta :ro
restic restore latest --no-lock --target "$WORKDIR"

DUMP_FILE=$(find "$WORKDIR" -name db.sql | head -1)
[ -n "$DUMP_FILE" ] || { echo "[restore-prod] no se encontró db.sql en el snapshot" >&2; exit 1; }

echo "[restore-prod] Recreando la base odoo (directo a db:5432, no pgbouncer)..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h db -p 5432 -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'odoo' AND pid <> pg_backend_pid();
DROP DATABASE IF EXISTS odoo;
CREATE DATABASE odoo;
SQL

echo "[restore-prod] Cargando dump en odoo..."
PGPASSWORD="$POSTGRES_PASSWORD" psql -h db -p 5432 -U "$POSTGRES_USER" -d odoo \
  -v ON_ERROR_STOP=1 -f "$DUMP_FILE"

echo "[restore-prod] Copiando filestore (odoo/)..."
FILESTORE_SRC=$(find "$WORKDIR" -type d -path '*/filestore/odoo' | head -1)
[ -n "$FILESTORE_SRC" ] || { echo "[restore-prod] no se encontró el filestore en el snapshot" >&2; exit 1; }
mkdir -p /filestore/.local/share/Odoo/filestore/odoo
rm -rf /filestore/.local/share/Odoo/filestore/odoo/*
cp -r "$FILESTORE_SRC/." /filestore/.local/share/Odoo/filestore/odoo/

# Odoo corre como 100:101, nunca root — mismo fix que restore-staging.sh.
chown -R 100:101 /filestore

echo "[restore-prod] OK"

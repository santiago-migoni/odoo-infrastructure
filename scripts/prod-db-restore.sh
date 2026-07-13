#!/bin/sh
# Orquesta el restore de disaster recovery de prod: guard de confirmación,
# elige la fuente (R2 por defecto, LOCAL=yes fuerza el repo local), para
# odoo+pgbouncer para liberar conexiones a la DB, corre restore-prod.sh
# dentro de la imagen de herramientas, y solo reinicia si salió bien. Bajo
# `set -e`: un fallo del restore corta acá — Odoo queda parado, nunca
# sirviendo sobre una DB a medio restaurar.
set -e
cd "$(dirname "$0")/.."

if [ "$CONFIRM" != "yes" ]; then
  echo "[prod-db-restore] ABORTADO: falta CONFIRM=yes. Este restore sobrescribe la DB y el filestore de producción." >&2
  echo "[prod-db-restore] Uso: make prod-db-restore CONFIRM=yes [LOCAL=yes]" >&2
  exit 1
fi

. ./env/.env.backup
. ./env/.env.prod

if [ "$LOCAL" = "yes" ]; then
  echo "[prod-db-restore] Fuente: repo restic LOCAL ($RESTIC_REPOSITORY_LOCAL)"
  export RESTIC_REPOSITORY="$RESTIC_REPOSITORY_LOCAL"
else
  echo "[prod-db-restore] Fuente: repo restic R2 ($RESTIC_REPOSITORY_R2) — off-site, default de disaster recovery"
  export RESTIC_REPOSITORY="$RESTIC_REPOSITORY_R2"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
fi

echo "[prod-db-restore] Construyendo imagen de herramientas (restic + psql, docker/Dockerfile.backup)..."
docker build -f docker/Dockerfile.backup -t odoo-restore-tools:local . >/dev/null

echo "[prod-db-restore] Parando odoo + pgbouncer (liberar conexiones a la DB)..."
docker compose -f docker/docker-compose.prod.yml stop odoo pgbouncer

echo "[prod-db-restore] Restaurando..."
docker run --rm --network odoo-shared \
  -e RESTIC_REPOSITORY="$RESTIC_REPOSITORY" \
  -e RESTIC_PASSWORD="$RESTIC_PASSWORD" \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -v /srv/odoo-backups:/backups:ro \
  -v odoo-data:/filestore \
  -v "$(pwd)/scripts/restore-prod.sh:/restore-prod.sh:ro" \
  --entrypoint sh \
  odoo-restore-tools:local /restore-prod.sh

echo "[prod-db-restore] Restore OK — levantando prod..."
docker compose -f docker/docker-compose.prod.yml up -d

echo "[prod-db-restore] OK"

#!/bin/sh
# Orquesta el ciclo completo de staging en orden crítico: si ya está activa,
# teardown + fresh (baja y vuelve a empezar); levanta solo `db`; restore;
# anonimización; recién ahí Odoo. Bajo `set -e`: cualquier fallo antes del
# `up -d odoo-staging` corta acá — nunca queda un Odoo vivo sobre datos de
# prod sin anonimizar.
set -e
cd "$(dirname "$0")/.."

. ./env/.env.staging

if docker compose -f docker/docker-compose.staging.yml ps -q db 2>/dev/null | grep -q .; then
  echo "[staging-up] staging ya está activa — bajando para un ciclo nuevo (teardown + fresh restore)..."
  ./scripts/staging-down.sh
fi

echo "[staging-up] Construyendo imagen de herramientas (restic + psql, docker/Dockerfile.backup)..."
docker build -f docker/Dockerfile.backup -t odoo-restore-tools:local . >/dev/null

echo "[staging-up] Levantando solo db..."
docker compose -f docker/docker-compose.staging.yml up -d --wait db

echo "[staging-up] Restaurando el último backup (repo restic local)..."
docker run --rm --network staging-net --env-file env/.env.staging \
  -v /srv/odoo-backups:/backups:ro \
  -v odoo-data-staging:/staging-data \
  -v "$(pwd)/scripts/restore-staging.sh:/restore-staging.sh:ro" \
  --entrypoint sh \
  odoo-restore-tools:local /restore-staging.sh

echo "[staging-up] Anonimizando (psql --single-transaction, directo a db:5432)..."
docker run --rm --network staging-net \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  -v "$(pwd)/scripts/anonymize-staging.sql:/anonymize-staging.sql:ro" \
  --entrypoint psql \
  odoo-restore-tools:local \
  -h db -p 5432 -U "$POSTGRES_USER" -d odoo_staging -v ON_ERROR_STOP=1 --single-transaction -f /anonymize-staging.sql

echo "[staging-up] Restore y anonimización OK — levantando pgbouncer + odoo-staging + postgres-exporter..."
docker compose -f docker/docker-compose.staging.yml up -d pgbouncer odoo-staging postgres-exporter

echo "[staging-up] Armando teardown duro (~3h)..."
./scripts/staging-extend.sh

echo "[staging-up] OK — staging arriba en https://staging.miempresa.com"

#!/bin/sh
# Idempotente: crea el rol de solo lectura usado por postgres-exporter-prod
# (GRANT pg_monitor, no el superusuario), o sincroniza su password si ya
# existe. Se corre a mano, contra el servicio `db` (ver INSTALL.md).
# Lee POSTGRES_USER de env/.env.prod; requiere MONITORING_DB_PASSWORD en el
# entorno (el mismo valor que después va en env/.env.monitoring).
set -e
cd "$(dirname "$0")/.."

: "${MONITORING_DB_PASSWORD:?falta MONITORING_DB_PASSWORD en el entorno}"
. ./env/.env.prod

docker compose -f Docker/docker-compose.prod.yml exec -T db psql -U "$POSTGRES_USER" -d odoo <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'monitoring') THEN
    CREATE ROLE monitoring WITH LOGIN PASSWORD '${MONITORING_DB_PASSWORD}';
  ELSE
    ALTER ROLE monitoring WITH PASSWORD '${MONITORING_DB_PASSWORD}';
  END IF;
END
\$\$;

GRANT pg_monitor TO monitoring;
SQL

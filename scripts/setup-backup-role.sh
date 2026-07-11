#!/bin/sh
# Idempotente: crea el rol de solo lectura usado por el contenedor de backup,
# o sincroniza su password si ya existe (re-correr con un BACKUP_DB_PASSWORD
# distinto actualiza el rol, no lo deja pegado al valor de la primera corrida).
# Se corre a mano, contra el servicio `db` (ver INSTALL.md).
# Lee POSTGRES_USER de .env.prod; requiere BACKUP_DB_PASSWORD en el entorno
# (el mismo valor que después va en .env.backup).
set -e
cd "$(dirname "$0")/.."

: "${BACKUP_DB_PASSWORD:?falta BACKUP_DB_PASSWORD en el entorno}"
. ./.env.prod

docker compose -f docker-compose.prod.yml exec -T db psql -U "$POSTGRES_USER" -d odoo <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'backup_readonly') THEN
    CREATE ROLE backup_readonly WITH LOGIN PASSWORD '${BACKUP_DB_PASSWORD}';
  ELSE
    ALTER ROLE backup_readonly WITH PASSWORD '${BACKUP_DB_PASSWORD}';
  END IF;
END
\$\$;

GRANT CONNECT ON DATABASE odoo TO backup_readonly;
GRANT USAGE ON SCHEMA public TO backup_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_readonly;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO backup_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO backup_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO backup_readonly;
SQL

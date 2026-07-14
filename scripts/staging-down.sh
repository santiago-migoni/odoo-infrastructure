#!/bin/sh
# Baja staging (destruye sus volúmenes). Destructivo y deliberado — se corre
# a mano, o como parte del teardown+fresh de staging-up.sh cuando ya está activa.
set -e
cd "$(dirname "$0")/.."

docker compose -f docker/docker-compose.staging.yml down -v

echo "[staging] bajada, volúmenes destruidos"

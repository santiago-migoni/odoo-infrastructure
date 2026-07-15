#!/bin/sh
# Baja staging (destruye sus volúmenes). Destructivo y deliberado — se corre
# a mano, o como parte del teardown+fresh de refresh-staging.sh cuando ya está activa.
set -e
cd "$(dirname "$0")/.."

docker compose -f staging/docker/docker-compose.yml down -v

echo "[nuke-staging] bajada, volúmenes destruidos"

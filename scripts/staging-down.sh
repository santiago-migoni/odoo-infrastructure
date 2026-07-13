#!/bin/sh
# Baja staging (destruye sus volúmenes) y cancela el timer transiente de
# teardown si estaba armado. Se corre a mano, o disparado por el timer/boot.
set -e
cd "$(dirname "$0")/.."

docker compose -f docker-compose.staging.yml down -v
sudo systemctl stop odoo-staging-teardown.timer 2>/dev/null || true

echo "[staging] bajada, volúmenes destruidos"

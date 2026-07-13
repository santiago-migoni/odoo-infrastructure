#!/bin/sh
# Arma o reprograma el teardown duro de staging a ~3h desde ahora. La
# reprogramación es destructiva del timer anterior (se para y se re-crea),
# nunca acumulativa. Usado tanto por staging-up.sh (arranque) como por el
# operador (extender una sesión en curso).
set -e
cd "$(dirname "$0")/.."

sudo systemctl stop odoo-staging-teardown.timer 2>/dev/null || true
sudo systemd-run --unit=odoo-staging-teardown --on-active=3h \
  --description="Teardown duro de staging" \
  /bin/sh "$(pwd)/scripts/staging-down.sh"

echo "[staging] teardown reprogramado a ~3h desde ahora"

#!/bin/sh
set -e

# Usa el propio parser de config de Odoo (no un grep) para chequear los
# valores efectivos que Odoo va a ver al arrancar, no el texto crudo del ini.
python3 -c "
from odoo.tools import config

config.parse_config(['-c', '${ODOO_RC:-/etc/odoo/odoo.conf}'], setup_logging=False)

errors = []
if config['list_db'] is not False:
    errors.append(f\"list_db={config['list_db']!r}, must be False\")
if config['proxy_mode'] is not True:
    errors.append(f\"proxy_mode={config['proxy_mode']!r}, must be True\")
if errors:
    raise SystemExit('odoo-entrypoint: config check failed: ' + '; '.join(errors))
"

exec /entrypoint.sh "$@"

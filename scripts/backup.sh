#!/bin/sh
set -e

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DAY_OF_WEEK=$(date +%u)   # 1=lunes .. 7=domingo
DAY_OF_MONTH=$(date +%d)

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

DUMP_FILE="$WORKDIR/db-$TIMESTAMP.dump"
FILESTORE_FILE="$WORKDIR/filestore-$TIMESTAMP.tar.gz"

echo "[backup] Volcando base de datos..."
pg_dump -Fc -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -f "$DUMP_FILE"

echo "[backup] Empaquetando filestore..."
tar czf "$FILESTORE_FILE" -C /filestore/.local/share/Odoo/filestore/odoo .

echo "[backup] Cifrando..."
gpg --batch --yes --passphrase "$GPG_PASSPHRASE" --symmetric --cipher-algo AES256 -o "$DUMP_FILE.gpg" "$DUMP_FILE"
gpg --batch --yes --passphrase "$GPG_PASSPHRASE" --symmetric --cipher-algo AES256 -o "$FILESTORE_FILE.gpg" "$FILESTORE_FILE"

echo "[backup] Copiando a retención local ($LOCAL_BACKUP_DIR)..."
mkdir -p "$LOCAL_BACKUP_DIR"
cp "$DUMP_FILE.gpg" "$FILESTORE_FILE.gpg" "$LOCAL_BACKUP_DIR/"
find "$LOCAL_BACKUP_DIR" -type f -mtime +7 -delete

echo "[backup] Subiendo a $RCLONE_DEST/daily/..."
rclone copy "$DUMP_FILE.gpg" "$RCLONE_DEST/daily/"
rclone copy "$FILESTORE_FILE.gpg" "$RCLONE_DEST/daily/"

if [ "$DAY_OF_WEEK" = "7" ]; then
  echo "[backup] Domingo — copiando también a weekly/..."
  rclone copy "$DUMP_FILE.gpg" "$RCLONE_DEST/weekly/"
  rclone copy "$FILESTORE_FILE.gpg" "$RCLONE_DEST/weekly/"
fi

if [ "$DAY_OF_MONTH" = "01" ]; then
  echo "[backup] Día 1 del mes — copiando también a monthly/..."
  rclone copy "$DUMP_FILE.gpg" "$RCLONE_DEST/monthly/"
  rclone copy "$FILESTORE_FILE.gpg" "$RCLONE_DEST/monthly/"
fi

echo "[backup] Podando remoto vencido..."
# Best-effort: si daily/weekly/monthly todavía no existen (nunca se les copió
# nada, ej. antes del primer domingo/día 1), no hay nada que podar — no debe
# tumbar un backup que ya se generó y subió correctamente.
rclone delete "$RCLONE_DEST/daily/" --min-age 30d || true
rclone delete "$RCLONE_DEST/weekly/" --min-age 90d || true
rclone delete "$RCLONE_DEST/monthly/" --min-age 365d || true

echo "[backup] OK"

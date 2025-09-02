#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="${1:-$PWD/backups}"
VOLUMES="${VOLUMES:-django_media,django_static,django_db_data}"
mkdir -p "$BACKUP_DIR"
DATE=$(date +"%Y%m%d-%H%M%S")
IFS=',' read -ra VOLS <<< "$VOLUMES"
for VOL in "${VOLS[@]}"; do
  OUT="$BACKUP_DIR/${VOL}_${DATE}.tgz"
  echo "Backup $VOL -> $OUT"
  docker run --rm -v "${VOL}:/data:ro" -v "${BACKUP_DIR}:/backup" alpine:3.20 \
    sh -c "tar czf /backup/$(basename "$OUT") -C /data ."
done
echo "Backups OK -> $BACKUP_DIR"

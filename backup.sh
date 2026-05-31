#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }

: "${GCS_BUCKET:?ERROR: GCS_BUCKET environment variable is required}"

VOLUMES_PATH="${VOLUMES_PATH:-/volumes}"
BACKUP_PREFIX="${BACKUP_PREFIX:-dokploy-backups}"
BACKUP_HOSTNAME="${BACKUP_HOSTNAME:-$(hostname)}"
TIMESTAMP="$(date -u +"%Y%m%d_%H%M%S")"

if [ ! -d "$VOLUMES_PATH" ]; then
    log "ERROR: Volumes path '$VOLUMES_PATH' does not exist"
    exit 1
fi

mapfile -t volume_dirs < <(find "$VOLUMES_PATH" -mindepth 1 -maxdepth 1 -type d | sort)

if [ "${#volume_dirs[@]}" -eq 0 ]; then
    log "WARNING: No volume directories found in '$VOLUMES_PATH'"
    exit 0
fi

SUCCESS=0
FAILED=0

for volume_dir in "${volume_dirs[@]}"; do
    volume_name="$(basename "$volume_dir")"
    archive_name="${BACKUP_HOSTNAME}_${volume_name}_${TIMESTAMP}.tar.gz"
    gcs_dest="gcs:${GCS_BUCKET}/${BACKUP_PREFIX}/${volume_name}/${archive_name}"

    log "Backing up '$volume_name' -> $gcs_dest"

    if tar -czf - -C "$VOLUMES_PATH" "$volume_name" 2>/dev/null | rclone rcat "$gcs_dest"; then
        log "OK: $volume_name"
        SUCCESS=$((SUCCESS + 1))
    else
        log "FAILED: $volume_name"
        FAILED=$((FAILED + 1))
    fi
done

log "Done. Success: $SUCCESS  Failed: $FAILED"

if [ -n "${BACKUP_RETENTION_DAYS:-}" ] && [ "$BACKUP_RETENTION_DAYS" -gt 0 ]; then
    log "Pruning backups older than ${BACKUP_RETENTION_DAYS} days from gcs:${GCS_BUCKET}/${BACKUP_PREFIX}/"
    rclone delete --min-age "${BACKUP_RETENTION_DAYS}d" "gcs:${GCS_BUCKET}/${BACKUP_PREFIX}/"
fi

[ "$FAILED" -eq 0 ]

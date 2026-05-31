#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }

# Write rclone config for GCS remote named "gcs"
setup_rclone() {
    mkdir -p /root/.config/rclone

    cat > /root/.config/rclone/rclone.conf <<EOF
[gcs]
type = google cloud storage
EOF

    if [ -n "${GCS_SERVICE_ACCOUNT_JSON:-}" ]; then
        # Base64-encoded service account JSON supplied via env var
        echo "$GCS_SERVICE_ACCOUNT_JSON" | base64 -d > /run/gcs-key.json
        chmod 600 /run/gcs-key.json
        echo "service_account_file = /run/gcs-key.json" >> /root/.config/rclone/rclone.conf
        log "Loaded GCS credentials from GCS_SERVICE_ACCOUNT_JSON"
    elif [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]; then
        # Path to a mounted service account key file
        echo "service_account_file = ${GOOGLE_APPLICATION_CREDENTIALS}" >> /root/.config/rclone/rclone.conf
        log "Loaded GCS credentials from GOOGLE_APPLICATION_CREDENTIALS"
    else
        # Fall through to Application Default Credentials (useful on GCE/GKE)
        log "WARNING: No explicit GCS credentials provided; using Application Default Credentials"
    fi

    if [ -n "${GCS_PROJECT_ID:-}" ]; then
        echo "project_number = ${GCS_PROJECT_ID}" >> /root/.config/rclone/rclone.conf
    fi
}

setup_rclone

# Optional: run a backup immediately when the container starts
if [ "${RUN_ON_STARTUP:-false}" = "true" ]; then
    log "RUN_ON_STARTUP=true — running initial backup"
    /usr/local/bin/backup.sh || log "WARNING: Initial backup failed"
fi

BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-0 2 * * *}"

# Write the crontab for root
mkdir -p /etc/crontabs
printf '%s /usr/local/bin/backup.sh\n' "$BACKUP_SCHEDULE" > /etc/crontabs/root

log "Backup scheduler started (schedule: '$BACKUP_SCHEDULE')"
log "Volumes mounted at: ${VOLUMES_PATH:-/volumes}"
log "Destination bucket: ${GCS_BUCKET:-<not set>}"

# Run crond in the foreground so Docker sees it as PID 1's child
exec crond -f -l 6

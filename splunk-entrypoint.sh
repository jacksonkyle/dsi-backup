#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }

: "${SPLUNK_HOST:?ERROR: SPLUNK_HOST is required}"
: "${SPLUNK_TOKEN:?ERROR: SPLUNK_TOKEN is required}"
: "${SPLUNK_QUERY:?ERROR: SPLUNK_QUERY is required}"
: "${TEAMS_WEBHOOK_URL:?ERROR: TEAMS_WEBHOOK_URL is required}"

if [ "${RUN_ON_STARTUP:-false}" = "true" ]; then
    log "RUN_ON_STARTUP=true — running initial check"
    /usr/local/bin/splunk-alert.sh || log "WARNING: Initial check failed"
fi

CHECK_SCHEDULE="${CHECK_SCHEDULE:-*/15 * * * *}"

mkdir -p /etc/crontabs
printf '%s /usr/local/bin/splunk-alert.sh >> /var/log/splunk-alert.log 2>&1\n' \
    "$CHECK_SCHEDULE" > /etc/crontabs/root

log "Splunk alert checker started"
log "Schedule:   $CHECK_SCHEDULE"
log "Host:       $SPLUNK_HOST"
log "Query:      $SPLUNK_QUERY"
log "Time range: ${SPLUNK_TIMERANGE:--15m}"
log "Threshold:  ${ALERT_THRESHOLD:-1} event(s)"

exec crond -f -l 6

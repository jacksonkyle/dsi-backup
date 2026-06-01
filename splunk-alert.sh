#!/usr/bin/env bash
set -euo pipefail

log() { echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"; }

: "${SPLUNK_HOST:?ERROR: SPLUNK_HOST is required}"
: "${SPLUNK_TOKEN:?ERROR: SPLUNK_TOKEN is required}"
: "${SPLUNK_QUERY:?ERROR: SPLUNK_QUERY is required}"
: "${TEAMS_WEBHOOK_URL:?ERROR: TEAMS_WEBHOOK_URL is required}"

SPLUNK_TIMERANGE="${SPLUNK_TIMERANGE:--15m}"
ALERT_THRESHOLD="${ALERT_THRESHOLD:-1}"
MAX_POLL_SECONDS="${MAX_POLL_SECONDS:-60}"
RESULT_SAMPLE_SIZE="${RESULT_SAMPLE_SIZE:-5}"

AUTH_HEADER="Authorization: Bearer ${SPLUNK_TOKEN}"

# ── Step 1: create the search job ────────────────────────────────────────────
log "Querying Splunk (timerange: $SPLUNK_TIMERANGE): $SPLUNK_QUERY"

job_response=$(curl -sk \
    -H "$AUTH_HEADER" \
    "${SPLUNK_HOST}/services/search/jobs" \
    --data-urlencode "search=$SPLUNK_QUERY" \
    -d "earliest_time=${SPLUNK_TIMERANGE}" \
    -d "latest_time=now" \
    -d "output_mode=json")

sid=$(printf '%s' "$job_response" | jq -r '.sid // empty')

if [ -z "$sid" ]; then
    log "ERROR: Failed to create search job"
    log "Response: $job_response"
    exit 1
fi

log "Search job created: SID=$sid"

# ── Step 2: poll until the job completes ─────────────────────────────────────
deadline=$(($(date +%s) + MAX_POLL_SECONDS))

while true; do
    state=$(curl -sk \
        -H "$AUTH_HEADER" \
        "${SPLUNK_HOST}/services/search/jobs/${sid}?output_mode=json" \
        | jq -r '.entry[0].content.dispatchState // "UNKNOWN"')

    log "Job state: $state"

    [[ "$state" == "DONE" ]] && break

    if [[ "$state" == "FAILED" ]]; then
        log "ERROR: Search job failed"
        exit 1
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
        log "ERROR: Search job timed out after ${MAX_POLL_SECONDS}s"
        exit 1
    fi

    sleep 3
done

# ── Step 3: fetch results ─────────────────────────────────────────────────────
results_json=$(curl -sk \
    -H "$AUTH_HEADER" \
    "${SPLUNK_HOST}/services/search/jobs/${sid}/results?output_mode=json&count=${RESULT_SAMPLE_SIZE}")

result_count=$(printf '%s' "$results_json" | jq '.results | length')
log "Found $result_count result(s) (threshold: $ALERT_THRESHOLD)"

if [ "$result_count" -lt "$ALERT_THRESHOLD" ]; then
    log "Below threshold — no alert sent"
    exit 0
fi

# ── Step 4: format results for the Teams message ──────────────────────────────
# Show _raw log lines when available; fall back to key=value pairs
sample_text=$(printf '%s' "$results_json" | jq -r '
    .results |
    map(
        if ._raw then ._raw | gsub("\r";"") | ltrimstr("\n")
        else to_entries
            | map(select(.key | startswith("_") | not))
            | map("\(.key)=\(.value)")
            | join("  ")
        end
    ) |
    join("\n")
')

# ── Step 5: post to Teams ─────────────────────────────────────────────────────
log "Sending Teams alert ($result_count event(s) found)"

timestamp="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

teams_payload=$(jq -n \
    --arg query    "$SPLUNK_QUERY" \
    --arg count    "$result_count" \
    --arg range    "$SPLUNK_TIMERANGE" \
    --arg host     "$SPLUNK_HOST" \
    --arg sample   "$sample_text" \
    --arg ts       "$timestamp" \
    '{
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": "FF0000",
        "summary": ("Splunk Alert: " + $count + " event(s) found"),
        "sections": [
            {
                "activityTitle": "Splunk Alert",
                "activitySubtitle": ($count + " event(s) matched in the last " + $range + " as of " + $ts),
                "facts": [
                    { "name": "Query",        "value": $query },
                    { "name": "Time Range",   "value": $range },
                    { "name": "Events Found", "value": $count },
                    { "name": "Splunk Host",  "value": $host  }
                ]
            },
            {
                "title": ("Sample events (up to " + ($count | tostring) + " shown)"),
                "text": ("<pre>" + $sample + "</pre>")
            }
        ],
        "potentialAction": [
            {
                "@type": "OpenUri",
                "name": "Open Splunk",
                "targets": [{ "os": "default", "uri": $host }]
            }
        ]
    }')

http_status=$(curl -sk -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "$teams_payload" \
    "$TEAMS_WEBHOOK_URL")

if [ "$http_status" = "200" ]; then
    log "Teams alert sent successfully"
else
    log "ERROR: Teams webhook returned HTTP $http_status"
    exit 1
fi

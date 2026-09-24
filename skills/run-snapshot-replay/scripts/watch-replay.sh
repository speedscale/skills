#!/usr/bin/env bash
# Follow a Speedscale cloud replay report until it finishes, printing each
# status change and each new replay event (warnings, errors, and the operator's
# suggested resolutions) as it appears.
#
#   watch-replay.sh <report-id> [--interval 30] [--timeout 60m]
#
# Exit codes: 0 Passed, 1 Missed Goals, 2 Error or Canceled, 3 could not read
# the report, 124 timed out while still running. The last line printed is a
# JSON summary. Read-only: it never cancels or changes the replay.
set -euo pipefail

RID="${1:-}"
[ -n "$RID" ] && [ "${RID#-}" = "$RID" ] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
INTERVAL=30
TIMEOUT=60m
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

to_seconds() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *) echo "$1" ;;
  esac
}
deadline=$(( $(date +%s) + $(to_seconds "$TIMEOUT") ))

command -v speedctl >/dev/null || { echo "speedctl is required" >&2; exit 3; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 3; }

last_status=""
seen_events=""
failures=0
while :; do
  if ! report=$(speedctl get report "$RID" 2>/dev/null) || ! printf '%s' "$report" | jq -e '.report' >/dev/null 2>&1; then
    failures=$((failures + 1))
    if [ "$failures" -ge 5 ]; then
      echo "could not read report $RID five times in a row (wrong tenant, not signed in, or no such report)" >&2
      exit 3
    fi
    sleep "$INTERVAL"
    continue
  fi
  failures=0

  status=$(printf '%s' "$report" | jq -r '.report.status // "Unknown"')
  if [ "$status" != "$last_status" ]; then
    echo "$(date -u +%H:%M:%SZ) status: $status"
    last_status="$status"
  fi

  # New replay events, oldest first, keyed by timestamp + name.
  while IFS=$'\t' read -r key line; do
    [ -n "$key" ] || continue
    case "$seen_events" in *"|$key|"*) continue ;; esac
    seen_events="$seen_events|$key|"
    echo "$line"
  done < <(printf '%s' "$report" | jq -r '
    (.report.replayEvents // []) | sort_by(.timestamp) | .[]
    | [(.timestamp + " " + (.name // "")),
       ("  event " + ((.severity // "") | sub("^RES_"; "")) + " " + (.reason // .name // "")
        + ": " + (.description // "")
        + (if (.resolutions // []) | length > 0
           then " (try: " + ([.resolutions[].resolution] | join("; ")) + ")" else "" end))]
    | @tsv')

  case "$status" in
    Passed|"Missed Goals"|Error|Canceled)
      printf '%s' "$report" | jq -c --arg id "$RID" '.report | {
        reportId: $id,
        status,
        snapshotId: .scenario.id,
        testConfig: (.actualConfig.id // .configId),
        cluster: .tags.k8sClusterName,
        namespace: .tags.ns,
        workload: .tags.workload,
        goals: [(.goals // [])[] | {status, command, expected, actual}],
        errorEvents: [(.replayEvents // [])[] | select(.severity == "RES_ERROR") | .reason]
      }'
      case "$status" in
        Passed) exit 0 ;;
        "Missed Goals") exit 1 ;;
        *) exit 2 ;;
      esac
      ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "still $status after $TIMEOUT; the replay keeps running, this watcher just stopped" >&2
    exit 124
  fi
  sleep "$INTERVAL"
done

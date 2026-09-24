#!/usr/bin/env bash
# Work out where a snapshot or recording should be replayed by default: the
# same place it was recorded. Prints one JSON object on stdout.
#
#   detect-replay-target.sh --snapshot-id <uuid>   # a snapshot in Speedscale cloud
#   detect-replay-target.sh --in <dir>             # a local recording or pulled snapshot
#
# Evidence, strongest first (the same order the dashboard's replay wizard uses
# to pre-fill its target, api-gateway RetrieveReplayDefaults):
#   1. the newest earlier replay of this snapshot: report tags k8sClusterName, ns, workload
#   2. the snapshot's own metadata: meta.namespaces[].inspector.clusterName + name, meta.serviceName
#   3. the recorded RRPairs' tags: k8sClusterName, k8sAppPodNamespace, k8sAppLabel
#      (cluster capture) versus none of those (a local proxymock recording)
# For a local origin the address the app listened on comes from
# 'proxymock cluster replay prepare', the busiest inbound slice.
#
# Read-only: it never starts, pushes, or changes anything.
set -euo pipefail

SNAPSHOT_ID=""
IN_DIR=""
MAX_FILES=${MAX_FILES:-400}

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot-id) SNAPSHOT_ID="$2"; shift 2 ;;
    --in) IN_DIR="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 2 ;;
  esac
done

if [ -z "$SNAPSHOT_ID" ] && [ -z "$IN_DIR" ]; then
  echo "pass --snapshot-id or --in" >&2
  usage 2
fi

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

have() { command -v "$1" >/dev/null 2>&1; }

emit() {
  # emit <origin> <cluster> <namespace> <workload> <evidence> [localAddress]
  jq -n \
    --arg snapshotId "$SNAPSHOT_ID" \
    --arg inDir "$IN_DIR" \
    --arg origin "$1" \
    --arg cluster "$2" \
    --arg namespace "$3" \
    --arg workload "$4" \
    --arg evidence "$5" \
    --arg localAddress "${6:-}" \
    --argjson registered "${REGISTERED:-null}" \
    --argjson priorReport "${PRIOR_REPORT:-null}" \
    '{
      origin: $origin,
      snapshotId: (if $snapshotId == "" then null else $snapshotId end),
      inDir: (if $inDir == "" then null else $inDir end),
      cluster: (if $cluster == "" then null else $cluster end),
      namespace: (if $namespace == "" then null else $namespace end),
      # a report tag lists every routed workload, comma-separated
      workloads: ($workload | split(",") | map(select(length > 0)) | unique),
      workload: ($workload | split(",") | map(select(length > 0)) | unique
                 | if length == 1 then .[0] else null end),
      clusterRegistered: $registered,
      localAddress: (if $localAddress == "" then null else $localAddress end),
      priorReport: $priorReport,
      evidence: $evidence
    }'
}

# Is <cluster> registered with the tenant (so a cloud replay can reach it)?
check_registered() {
  REGISTERED=null
  [ -n "$1" ] || return 0
  have speedctl || return 0
  local list
  list=$(speedctl infra inspectors 2>/dev/null || true)
  [ -n "$list" ] || return 0
  if printf '%s' "$list" | jq -e --arg c "$1" '[.. | objects | select((.cluster // .clusterName // .name) == $c)] | length > 0' >/dev/null 2>&1; then
    REGISTERED=true
  elif printf '%s' "$list" | grep -q -- "$1"; then
    REGISTERED=true
  else
    REGISTERED=false
  fi
}

# Busiest inbound slice of a recording, as an address a local replay can target.
local_address() {
  local dir="$1" prepared
  have proxymock || return 0
  prepared=$(proxymock cluster replay prepare --in "$dir" -o json 2>/dev/null || true)
  [ -n "$prepared" ] || return 0
  printf '%s' "$prepared" | jq -r '
    (.inbound // []) | sort_by(-(.numRequests // 0)) | .[0] // empty
    | "\(.protocol // "http")://\(.hostname):\(.port)"' 2>/dev/null || true
}

# Tags from the inbound RRPairs of a directory, as one JSON object of the most
# common value per key. Handles markdown and JSON RRPair files.
inbound_tags() {
  local dir="$1"
  {
    # Outbound pairs usually outnumber inbound ones, so pick inbound files first.
    find "$dir" -name '*.md' -not -path '*/.metadata/*' -print0 2>/dev/null \
      | xargs -0 grep -l '^direction: IN' 2>/dev/null | head -n "$MAX_FILES" | while IFS= read -r f; do
      awk '
        /^direction: / { dir = $2 }
        /^tags: / { sub(/^tags: /, ""); tags = $0 }
        END { if (dir == "IN") print tags }
      ' "$f"
    done | tr ',' '\n' | sed 's/^ *//' | grep '=' || true
    find "$dir" -name '*.json' -not -path '*/.metadata/*' 2>/dev/null | head -n "$MAX_FILES" | while IFS= read -r f; do
      jq -r 'select(type == "object" and .direction == "IN") | (.tags // {}) | to_entries[] | "\(.key)=\(.value)"' "$f" 2>/dev/null || true
    done
  } | awk -F= '
      $1 ~ /^(k8sClusterName|k8sAppPodNamespace|k8sAppLabel|k8sNamespace|source|captureMode|reverseProxyHost|reverseProxyPort)$/ {
        n[$1 "\t" $2]++
      }
      END { for (k in n) print n[k] "\t" k }
    ' | sort -rn | awk -F'\t' '!seen[$2]++ { print $2 "\t" $3 }' \
    | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {(.[0]): .[1]}) | add // {}'
}

from_dir() {
  local dir="$1" meta tags cluster ns workload addr
  [ -d "$dir" ] || { echo "not a directory: $dir" >&2; exit 2; }

  # A pulled snapshot carries its cloud metadata.
  meta=""
  for m in "$dir/.metadata/snapshot.json" "$dir"/snapshot-*/.metadata/snapshot.json; do
    if [ -f "$m" ] && jq -e '.meta.namespaces[0].inspector.clusterName // empty' "$m" >/dev/null 2>&1; then
      meta="$m"; break
    fi
  done
  if [ -n "$meta" ]; then
    [ -n "$SNAPSHOT_ID" ] || SNAPSHOT_ID=$(jq -r '.id // empty' "$meta")
    cluster=$(jq -r '.meta.namespaces[0].inspector.clusterName // empty' "$meta")
    ns=$(jq -r '.meta.namespaces[0].name // empty' "$meta")
  fi

  tags=$(inbound_tags "$dir")
  [ -n "${cluster:-}" ] || cluster=$(printf '%s' "$tags" | jq -r '.k8sClusterName // empty')
  [ -n "${ns:-}" ] || ns=$(printf '%s' "$tags" | jq -r '.k8sAppPodNamespace // .k8sNamespace // empty')
  workload=$(printf '%s' "$tags" | jq -r '.k8sAppLabel // empty')

  if [ -n "${cluster:-}" ]; then
    check_registered "$cluster"
    emit cluster "$cluster" "${ns:-}" "$workload" \
      "inbound RRPairs were captured in cluster $cluster (tags k8sClusterName/k8sAppPodNamespace/k8sAppLabel${meta:+, and the pulled snapshot metadata})"
    return
  fi

  addr=$(local_address "$dir")
  if [ -z "$addr" ]; then
    local h p
    h=$(printf '%s' "$tags" | jq -r '.reverseProxyHost // empty')
    p=$(printf '%s' "$tags" | jq -r '.reverseProxyPort // empty')
    [ -n "$h" ] && [ -n "$p" ] && addr="http://$h:$p"
  fi
  if [ "$(printf '%s' "$tags" | jq 'length')" = "0" ] && [ -z "$addr" ]; then
    emit unknown "" "" "" "no inbound RRPairs found under $dir"
    return
  fi
  emit local "" "" "$workload" \
    "inbound RRPairs carry no Kubernetes cluster tags, so they were recorded by proxymock on a developer machine" "$addr"
}

from_snapshot_id() {
  have speedctl || { echo "speedctl is needed to read a cloud snapshot's metadata; pull it with 'proxymock cloud pull snapshot $SNAPSHOT_ID' and pass --in instead" >&2; exit 2; }
  local snap reports report cluster ns workload

  # 1. The newest earlier replay of this snapshot.
  reports=$(speedctl get reports 2>/dev/null || echo '{}')
  report=$(printf '%s' "$reports" | jq -r --arg id "$SNAPSHOT_ID" '
    [(.records // [])[] | select(.scenarioId == $id)] | sort_by(.startTime) | reverse | .[0].Id // empty' 2>/dev/null || true)
  if [ -n "$report" ]; then
    local r
    r=$(speedctl get report "$report" 2>/dev/null | jq -c '.report | {id: "'"$report"'", status, cluster: .tags.k8sClusterName, namespace: .tags.ns, workload: .tags.workload, testConfig: (.actualConfig.id // .configId), replayMode: .actualConfig.cluster.replayMode, replaySource: .tags.replaySource}' 2>/dev/null || true)
    if [ -n "$r" ] && [ "$(printf '%s' "$r" | jq -r '.cluster // empty')" != "" ]; then
      PRIOR_REPORT="$r"
      cluster=$(printf '%s' "$r" | jq -r '.cluster // empty')
      ns=$(printf '%s' "$r" | jq -r '.namespace // empty')
      workload=$(printf '%s' "$r" | jq -r '.workload // empty')
      check_registered "$cluster"
      emit cluster "$cluster" "$ns" "$workload" "report $report last replayed this snapshot against $ns/${workload%%,*} in $cluster"
      return
    fi
  fi

  # 2. The snapshot's own metadata.
  snap=$(speedctl get snapshot "$SNAPSHOT_ID" 2>/dev/null || true)
  if ! printf '%s' "$snap" | jq -e . >/dev/null 2>&1; then
    echo "could not read snapshot $SNAPSHOT_ID (wrong tenant, or not signed in)" >&2
    exit 1
  fi
  cluster=$(printf '%s' "$snap" | jq -r '.meta.namespaces[0].inspector.clusterName // empty')
  ns=$(printf '%s' "$snap" | jq -r '.meta.namespaces[0].name // empty')
  workload=$(printf '%s' "$snap" | jq -r '.meta.serviceName // (.meta.services // [])[0] // empty')
  if [ -n "$cluster" ]; then
    check_registered "$cluster"
    emit cluster "$cluster" "$ns" "$workload" "snapshot metadata says it was captured from namespace $ns in cluster $cluster"
    return
  fi

  # 3. No cluster in the metadata: it was pushed from a local proxymock recording.
  emit local "" "" "$workload" \
    "snapshot has no cluster namespace in its metadata, so it was pushed from a local proxymock recording; pull it and run this again with --in to find the local address"
}

if [ -n "$IN_DIR" ]; then
  from_dir "$IN_DIR"
else
  from_snapshot_id
fi

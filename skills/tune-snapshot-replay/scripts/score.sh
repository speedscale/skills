#!/usr/bin/env bash
# Score one replay run so tuning iterations can be compared. Prints one JSON
# object: accuracy (did replayed responses match the recorded ones) and
# matchRate (did the mocks answer the app's outbound calls), plus goals.
#
#   score.sh <local-replay-dir | pulled-report-id> [--workspace <dir>]
#
# Uses `proxymock replay score` when the installed proxymock has it, and
# otherwise computes the same headline numbers from the files on disk:
#   local run:    <dir>/replay-verdict.json and the newest mocked-* run
#   cloud report: proxymock/reports/<id>.json and matches.grpc.jsonl
#                 (pull it first with `proxymock cloud pull report <id>`)
#
# Read-only.
set -euo pipefail

INPUT="${1:-}"
[ -n "$INPUT" ] || { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
shift
WORKSPACE="."
while [ $# -gt 0 ]; do
  case "$1" in
    --workspace) WORKSPACE="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

# `proxymock replay` accepts positional arguments, so on a proxymock without
# the score subcommand `replay score --help` still succeeds and prints the
# replay help. Require the score command's own usage line before using it.
if proxymock replay score --help 2>/dev/null | grep -q 'proxymock replay score'; then
  exec proxymock replay score "$INPUT" --in "$WORKSPACE" -o json
fi

# Count responder verdicts (HIT / MISS / PASSTHROUGH) in a mock output run.
mock_counts() {
  local dir="$1"
  find "$dir" -name '*.md' -print0 2>/dev/null \
    | xargs -0 awk '/^tags: /{ if (match($0, /match=[A-Z_]+/)) print substr($0, RSTART + 6, RLENGTH - 6) }' 2>/dev/null \
    | sort | uniq -c | awk '{ printf "{\"%s\": %s}\n", $2, $1 }' | jq -s 'add // {}'
}

match_rate_json() {
  # stdin: {"HIT": n, "MISS": n, "PASSTHROUGH": n}
  jq --arg source "$1" '
    (.HIT // 0) as $m | (.MISS // .NO_MATCH // 0) as $n | (.PASSTHROUGH // 0) as $p
    | ($m + $n + $p) as $t
    | {total: $t, matched: $m, noMatch: $n, passthrough: $p,
       rate: (if $t > 0 then ($m * 1000 / $t | round / 10) else null end),
       noMatchRate: (if $t > 0 then ($n * 1000 / $t | round / 10) else null end),
       passthroughRate: (if $t > 0 then ($p * 1000 / $t | round / 10) else null end),
       source: $source}'
}

if [ -f "$INPUT/replay-verdict.json" ]; then
  VERDICT="$INPUT/replay-verdict.json"
  mocked=$(find "$(dirname "$INPUT")" "$WORKSPACE/proxymock" -maxdepth 1 -type d -name 'mocked-*' 2>/dev/null | sort | tail -1)
  if [ -n "$mocked" ]; then
    match=$(mock_counts "$mocked" | match_rate_json "$mocked")
  else
    match=null
  fi
  jq --argjson matchRate "$match" --arg source "$VERDICT" '
    (.summary.pairs // 0) as $pairs | (.summary.mismatches // 0) as $mm
    | {kind: "local",
       accuracy: {pairs: $pairs, matched: ($pairs - $mm), mismatches: $mm,
                  statusMismatches: ([.pairs[]? | select(.recordedStatus != .observedStatus)] | length),
                  bodyMismatches: (.summary.bodyMismatches // 0),
                  rate: (if $pairs > 0 then (($pairs - $mm) * 1000 / $pairs | round / 10) else null end),
                  topFailingEndpoints: ([.pairs[]? | select(.match != "pass" or (.bodyMatch // "pass") == "fail")
                                | {method, endpoint}] | group_by([.method, .endpoint])
                                | map(.[0] + {failures: length}) | sort_by(-.failures) | .[0:5]),
                  source: $source},
       matchRate: $matchRate,
       goals: (if .goals == null then null else
                 {verdict: .goals.verdict,
                  passed: ([.goals.goals[]? | select(.status == "pass")] | length),
                  failed: ([.goals.goals[]? | select(.status == "fail")] | length),
                  goals: [.goals.goals[]? | {name, metric, condition, observed, status}]} end),
       notes: (if $matchRate == null then ["no mocked-* run found, so the mock match rate is unknown"] else [] end)}' "$VERDICT"
  exit 0
fi

# A cloud report id, already pulled into the workspace.
RPT_DIR="$WORKSPACE/proxymock/reports/$INPUT"
[ -f "$RPT_DIR.json" ] || RPT_DIR="${SPEEDSCALE_HOME:-$HOME/.speedscale}/data/reports/$INPUT"
if [ ! -f "$RPT_DIR.json" ]; then
  echo "no local run at $INPUT and no pulled report $INPUT; pull it with: proxymock cloud pull report $INPUT" >&2
  exit 1
fi
if [ -s "$RPT_DIR/matches.grpc.jsonl" ]; then
  match=$(jq -s 'map(.cacheStatus) | group_by(.) | map({(.[0]): length}) | add // {}
                 | {HIT: ((.MATCH // 0) + (.HIT // 0)), MISS: ((.NO_MATCH // 0) + (.MISS // 0)), PASSTHROUGH: (.PASSTHROUGH // 0)}' \
            "$RPT_DIR/matches.grpc.jsonl" | match_rate_json "$RPT_DIR/matches.grpc.jsonl")
else
  match=null
fi
# Replayed pairs carry tags.source == "generator" and tags.refUuid, which is
# the uuid of the recorded pair they replay. The recorded uuid is base64 bytes
# in JSON, so convert it before joining. (tags.file is empty in reports and
# tags.sequence collides across capture pods, so neither is a safe key.) Load
# replays keep only a sample, so this is a status-only figure over the pairs
# present; replayed pairs with no recorded match are counted, not guessed.
B64UUID='def b64uuid:
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" as $a
  | [explode[] | select(. != 61) | [.] | implode as $c | $a | index($c)]
  | [range(0; length; 4) as $i | .[$i:$i+4]]
  | map((.[0] * 262144 + (.[1] // 0) * 4096 + (.[2] // 0) * 64 + (.[3] // 0)) as $n
        | [($n / 65536 | floor), (($n / 256 | floor) % 256), ($n % 256)])
  | flatten | .[0:16]
  | map("0123456789abcdef" as $h | $h[(. / 16 | floor):(. / 16 | floor) + 1] + $h[(. % 16):(. % 16) + 1])
  | join("")
  | "\(.[0:8])-\(.[8:12])-\(.[12:16])-\(.[16:20])-\(.[20:32])";'
pairs=null
if [ -s "$RPT_DIR/generator-pairs.jsonl" ]; then
  pairs=$(jq -s -c "$B64UUID"'
    (map(select(.tags.source != "generator" and .uuid != null)) | map({key: (.uuid | b64uuid), value: .}) | from_entries) as $orig
    | map(select(.tags.source == "generator")
          | $orig[.tags.refUuid // ""] as $o
          | {method: (.http.req.method // .command), endpoint: .location, joined: ($o != null),
             ok: ($o != null and ((.http.res.statusCode // .status) == ($o.http.res.statusCode // $o.status)))})
    | map(select(.joined)) as $j
    | {pairs: ($j | length), matched: ($j | map(select(.ok)) | length),
       statusMismatches: ($j | map(select(.ok | not)) | length),
       unjoined: (map(select(.joined | not)) | length),
       topFailingEndpoints: ($j | map(select(.ok | not) | {method, endpoint}) | group_by([.method, .endpoint])
                             | map(.[0] + {failures: length}) | sort_by(-.failures) | .[0:5])}' "$RPT_DIR/generator-pairs.jsonl")
fi
jq --argjson matchRate "$match" --argjson pairs "$pairs" --arg source "$RPT_DIR.json" \
   --arg pairsSource "$RPT_DIR/generator-pairs.jsonl" '
  {kind: "cloud",
   status: .status,
   accuracy: ({reportSuccessRate: .successRate, source: $source}
              + (if $pairs == null then {} else $pairs + {
                   rate: (if $pairs.pairs > 0 then ($pairs.matched * 1000 / $pairs.pairs | round / 10) else null end),
                   basis: "status codes of replayed vs recorded pairs",
                   pairsSource: $pairsSource} end)),
   matchRate: $matchRate,
   goals: ([(.goals // [])[] | {name: "\(.command) \(.expected)", metric: .command, condition: .expected,
                                   observed: .actual, status: (.status | ascii_downcase)}]
           | {verdict: (if any(.[]; .status == "fail") then "fail" else "pass" end),
              passed: (map(select(.status == "pass")) | length),
              failed: (map(select(.status == "fail")) | length),
              goals: .}),
   notes: ((if $matchRate == null then ["the report has no mock match data (no responder, or an older report)"] else [] end)
           + (if ($pairs.unjoined // 0) > 0 then ["\($pairs.unjoined) replayed pairs had no recorded pair with a matching uuid and are not scored"] else [] end))}' "$RPT_DIR.json"

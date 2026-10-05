#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  proxymock-compare-results.sh --in DIR [--baseline DIR] [options]

Run a deep proxymock report over a set of RRPairs and, when a baseline is
given, a Compare report showing what regressed / improved / persisted across
Performance, Reliability, and Security. Writes report files to disk.

Required:
  --in DIR             Current RRPair directory to report on (e.g. a fresh
                       replay output, or a recording)

Options:
  --baseline DIR       Baseline RRPair directory. When set, output is a
                       before/after Compare report.
  --out-dir DIR        Where to write report files (default: timestamped dir)
  --drift              Also run `proxymock drift` between baseline and current
                       (requires --baseline) to list fields whose values vary
  --sensitivity TIER   drift tier: permissive | normal | strict (default normal)
  --fail-on-regression Exit nonzero if the Compare report lists any regression
  --proxymock PATH     proxymock binary (default: proxymock from PATH)
  -h, --help           Show this help

Output files (in --out-dir):
  report.json          machine-readable report
  report.html          self-contained HTML report (open in a browser)
  report.prompt.md     LLM-pasteable markdown digest (~2-4 KB)
  drift.json           (only with --drift) DriftReport with prefilled transforms

Examples:
  # single report over one recording
  proxymock-compare-results.sh --in ./proxymock/recorded-<name>

  # before/after: did anything regress between two replay runs?
  proxymock-compare-results.sh \
    --in ./proxymock/results/replayed-after \
    --baseline ./proxymock/results/replayed-before \
    --drift --fail-on-regression
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

abs_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd)
  else
    local dir base
    dir="$(dirname "$path")"
    base="$(basename "$path")"
    (cd "$dir" && printf '%s/%s\n' "$(pwd)" "$base")
  fi
}

in_dir=""
baseline_dir=""
out_dir=""
do_drift="0"
sensitivity="normal"
fail_on_regression="0"
proxymock_bin="${PROXYMOCK:-proxymock}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --in) [[ $# -ge 2 ]] || die "--in requires a value"; in_dir="$2"; shift 2 ;;
    --baseline) [[ $# -ge 2 ]] || die "--baseline requires a value"; baseline_dir="$2"; shift 2 ;;
    --out-dir) [[ $# -ge 2 ]] || die "--out-dir requires a value"; out_dir="$2"; shift 2 ;;
    --drift) do_drift="1"; shift ;;
    --sensitivity) [[ $# -ge 2 ]] || die "--sensitivity requires a value"; sensitivity="$2"; shift 2 ;;
    --fail-on-regression) fail_on_regression="1"; shift ;;
    --proxymock) [[ $# -ge 2 ]] || die "--proxymock requires a value"; proxymock_bin="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$in_dir" ]] || die "--in is required"
[[ -d "$in_dir" ]] || die "--in is not a directory: $in_dir"
[[ -z "$baseline_dir" || -d "$baseline_dir" ]] || die "--baseline is not a directory: $baseline_dir"
[[ "$do_drift" == "0" || -n "$baseline_dir" ]] || die "--drift requires --baseline"

if [[ "$proxymock_bin" == */* ]]; then
  [[ -x "$proxymock_bin" ]] || die "proxymock is not executable: $proxymock_bin"
else
  command -v "$proxymock_bin" >/dev/null 2>&1 || die "proxymock not found on PATH"
fi

in_dir="$(abs_path "$in_dir")"
[[ -n "$baseline_dir" ]] && baseline_dir="$(abs_path "$baseline_dir")"

if [[ -z "$out_dir" ]]; then
  out_dir="proxymock-compare-$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$out_dir"
out_dir="$(abs_path "$out_dir")"

base_args=(report --in "$in_dir")
if [[ -n "$baseline_dir" ]]; then
  base_args+=(--baseline "$baseline_dir")
  echo "comparing: baseline=${baseline_dir} -> current=${in_dir}"
else
  echo "reporting on: ${in_dir}"
fi

for fmt in json html prompt; do
  case "$fmt" in
    json) out="$out_dir/report.json" ;;
    html) out="$out_dir/report.html" ;;
    prompt) out="$out_dir/report.prompt.md" ;;
  esac
  "$proxymock_bin" "${base_args[@]}" --format "$fmt" --out "$out" --exit-zero
done

drift_json=""
if [[ "$do_drift" == "1" ]]; then
  drift_json="$out_dir/drift.json"
  echo "computing drift (${sensitivity})"
  "$proxymock_bin" drift \
    --source "$baseline_dir" \
    --source "$in_dir" \
    --sensitivity "$sensitivity" \
    --out "$drift_json"
fi

echo ""
echo "report files: $out_dir"
ls -1 "$out_dir"

# Gates read the native wire format; absent evidence is not zero regressions.
regressions=0
if [[ -n "$baseline_dir" ]]; then
  regressions="$(python3 - "$out_dir/report.json" <<'PYJSON'
import json, sys
report = json.load(open(sys.argv[1]))
if not isinstance(report, dict) or not isinstance(report.get("baseline"), dict) or not isinstance(report.get("current"), dict):
    raise SystemExit("incomplete comparison: baseline or current report missing")
deltas = report.get("deltas")
if not isinstance(deltas, dict):
    raise SystemExit("incomplete comparison: deltas missing")
required = ("budgets", "outliers", "errorClusters", "findings")
if any(key not in deltas for key in required):
    raise SystemExit("incomplete comparison: expected delta sections missing")
budgets = deltas["budgets"]
if budgets is not None and (not isinstance(budgets, list) or any(not isinstance(item, dict) for item in budgets)):
    raise SystemExit("incomplete comparison: invalid budget deltas")
count = sum(item.get("verdict") == "regressed" for item in (budgets or []))
for section, key in (("outliers", "regressed"), ("errorClusters", "new"), ("findings", "new")):
    delta = deltas[section]
    if not isinstance(delta, dict) or key not in delta:
        raise SystemExit("incomplete comparison: invalid " + section + " deltas")
    items = delta[key]
    if items is not None and not isinstance(items, list):
        raise SystemExit("incomplete comparison: invalid " + section + " entries")
    count += len(items or [])
print(count)
PYJSON
)"
fi

echo "digest: $out_dir/report.prompt.md"
echo "open  : $out_dir/report.html"
[[ -n "$drift_json" ]] && echo "drift : $drift_json"

if [[ "$fail_on_regression" == "1" && -n "$baseline_dir" && "${regressions:-0}" -gt 0 ]]; then
  echo "FAIL: ${regressions} regression(s) detected" >&2
  exit 1
fi

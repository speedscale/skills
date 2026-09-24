#!/usr/bin/env bash
# Proves: the committed recording yields host, endpoint, and status summaries;
# a local report stub verifies digest append without cloud credentials.
set -euo pipefail

die() {
  echo "FAIL: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skill_dir="$(cd "$script_dir/.." && pwd)"
# The proofs run against the fixture recording committed in github.com/speedscale/mock-lab.
# When this skill lives inside that repo the fixture is two levels up; otherwise point
# MOCK_LAB_DIR at a checkout.
repo_root="${MOCK_LAB_DIR:-$(cd "$skill_dir/../.." && pwd)}"
if [[ ! -d "$repo_root/lab/proxymock/recording" ]]; then
  echo "mock-lab fixture not found at $repo_root; set MOCK_LAB_DIR to a checkout of https://github.com/speedscale/mock-lab" >&2
  exit 1
fi
summarize_script="$script_dir/proxymock-summarize-recording.sh"

need_cmd python3
[[ -x "$summarize_script" ]] || die "summarize script is not executable: $summarize_script"

recording="$repo_root/lab/proxymock/recording"
[[ -d "$recording" ]] || die "missing committed recording: $recording"

tmp="${TMPDIR:-/tmp}/proxymock-summarize-proof.$$"
cleanup() {
  if [[ "${KEEP_PROOF_TMP:-0}" != "1" ]]; then
    rm -rf "$tmp"
  else
    echo "kept proof workspace: $tmp"
  fi
}
trap cleanup EXIT
mkdir -p "$tmp"

cat > "$tmp/proxymock-stub" <<'SH'
#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = --out ]; then out=$2; shift 2; else shift; fi
done
[ -n "$out" ] || exit 1
printf '## Security\nLocal report digest\n' > "$out"
SH
chmod +x "$tmp/proxymock-stub"

out="$tmp/summary.md"
"$summarize_script" --in "$recording" --out "$out" --work-dir "$tmp" --proxymock "$tmp/proxymock-stub" >"$tmp/run.out" 2>&1 \
  || { cat "$tmp/run.out" >&2; die "summarize exited nonzero"; }
cat "$tmp/run.out"

[[ -s "$out" ]] || die "summary markdown was not written"

python3 - "$out" <<'PY'
import re, sys
text = open(sys.argv[1]).read()

def need(cond, msg):
    if not cond:
        raise SystemExit(f"summary missing: {msg}")

need("demo-api.trafficreplay.com" in text, "downstream host demo-api.trafficreplay.com")
need(re.search(r"^##\s+Inbound endpoints", text, re.M), "Inbound endpoints section")
need(re.search(r"^##\s+Outbound endpoints", text, re.M), "Outbound endpoints section")
need("/v1/" in text, "an outbound /v1/* downstream endpoint")
need(re.search(r"\*\*Status mix:\*\*.*2xx", text), "a 2xx status mix line")
need(re.search(r"^##\s+Findings & recommendations", text, re.M), "report digest section")
need("Security" in text or "Performance" in text, "a report pillar in the digest")
print("PASS: summary enumerates host, inbound + outbound endpoints, status mix, and digest")
PY

mkdir -p "$tmp/sql-recording"
cat > "$tmp/sql-recording/query.json" <<'JSON'
{"direction":"OUT","l7protocol":"postgres","command":"SELECT","location":"orders","netinfo":{"upstream":{"hostname":"db.internal"}},"postgres":{"req":{"query":"SELECT * FROM orders"},"res":{"rows":[]}}}
JSON
"$summarize_script" --in "$tmp/sql-recording" --out "$tmp/sql-summary.md" --work-dir "$tmp/sql-work" --no-report --proxymock "$tmp/proxymock-stub" >/dev/null
grep -q '\*\*RRPairs:\*\* 1' "$tmp/sql-summary.md" || die "non-HTTP RRPair was not counted"
grep -q 'postgres 1' "$tmp/sql-summary.md" || die "non-HTTP protocol was not reported"
echo "PASS: non-HTTP RRPairs are counted"

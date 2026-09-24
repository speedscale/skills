---
name: analyze-replay-report
description: Analyze a Speedscale or proxymock replay report and explain what happened, why it failed or passed, and what to do next. Use when the user pastes a report ID or a proxymock run directory, or asks "analyze this report", "why did this replay fail", "what does this report mean", "Missed Goals", "NO_MATCH", or "low success rate". Works on cloud reports (pulled with proxymock) and on local proxymock replay runs (replay-verdict.json). Read-only: it never re-runs a replay or changes config without asking.
---

# Analyze a replay report

Turn a replay report into a short, evidence-backed answer: what the verdict is,
what actually broke, whether it is the service under test (SUT), the mocks, the
environment, or the test config, and what to change next.

The rule that matters most: **read the first failing response body before
anything else.** The error body is ground truth. Logs, transforms, mock stats,
and infrastructure are indirect evidence and will mislead you if you start
there.

## Inputs

The user's prompt gives you one of these. Ask only if neither is present.

| Input | Looks like | Go to |
| --- | --- | --- |
| Cloud report ID | a UUID, often with a host such as `app.speedscale.com` | [Cloud report](#cloud-report) |
| Local run directory | a path under a proxymock workspace, e.g. `proxymock/results/replayed-3`, `proxymock/report-<uuid>` | [Local run](#local-run) |

A `report-<uuid>` run directory is a cloud report that was already pulled; use
the UUID and treat it as a cloud report.

## Prerequisites

- `proxymock` on PATH and signed in (`proxymock cloud pull` needs an API key
  for cloud reports; local runs need no account).
- `jq` for the one-liners below.

If proxymock is missing or not signed in, stop and use the
[`install-speedscale`](https://raw.githubusercontent.com/speedscale/skills/main/skills/install-speedscale/SKILL.md)
skill first (CLI and auth phases only; do not touch a cluster for this). If the
prompt named a host other than `app.speedscale.com`, pass it as
`--app-url <host>` when initializing.

Never print the API key. Never paste report response bodies containing tokens,
passwords, or personal data back to the user verbatim; summarize them.

## Cloud report

### 1. Pull it

Start from the directory containing `proxymock/`, or from `proxymock/` itself. Use the same workspace root for the pull and all report paths:

```bash
WORKSPACE_ROOT=$PWD
[ "$(basename "$WORKSPACE_ROOT")" = proxymock ] && WORKSPACE_ROOT=$(dirname "$WORKSPACE_ROOT")
(cd "$WORKSPACE_ROOT" && proxymock cloud pull report <report-id>)
```

That gives you two trees. Set `RPT_DIR` before running the commands below:

- `RPT_DIR`: the raw artifacts, plus metadata at `$RPT_DIR.json`. Current proxymock keeps them in the workspace; older versions used the Speedscale home directory. Take whichever exists:

  ```bash
  RPT_DIR="$WORKSPACE_ROOT/proxymock/reports/<report-id>"
  [ -f "$RPT_DIR.json" ] || RPT_DIR="${SPEEDSCALE_HOME:-$HOME/.speedscale}/data/reports/<report-id>"
  ```

- If `$RPT_DIR.json` still does not exist, stop and check the pull output before running the analysis commands.
- `$WORKSPACE_ROOT/proxymock/report-<report-id>/`: one markdown file per request, with mock match status, browsable with `proxymock web`. The source snapshot lands next to it as `$WORKSPACE_ROOT/proxymock/snapshot-<id>/` when it still exists.

If the pull fails with an auth or tenant error, the report probably belongs to
a different Speedscale tenant than the CLI is signed in to. Say so; do not
retry with other credentials.

If it fails with `all N RRPairs failed markdown conversion`, the artifacts in
`$RPT_DIR` still downloaded; only the markdown tree and the snapshot are
missing. Older proxymock stops there on reports whose mocks were Postgres,
MySQL, Kafka or AMQP. Carry on from `$RPT_DIR`, and pull the snapshot on its
own if you need the recorded side:

```bash
proxymock cloud pull snapshot "$(jq -r .scenario.id "$RPT_DIR.json")"
```

### 2. Read the verdict

```bash
jq '{status, successRate, scenario: .scenario.meta.name, snapshot: .scenario.id, testConfig: .configId}' "$RPT_DIR.json"
jq -r '.goals[] | [.status, .command, .expected, .actual] | @tsv' "$RPT_DIR.json"
wc -l "$RPT_DIR/generator-pairs.jsonl"
```

- `status`: `Passed`, `Missed Goals`, or `Error`. `Missed Goals` means the
  replay ran and a goal failed; `Error` usually means it never ran properly.
- Every `FAIL` goal is a lead. `expected` vs `actual` often says it all:
  `totalTransactionCount <= 0, actual 4` is a goal set too strict, not a bug.
- `generator-pairs.jsonl` with 0 lines means the replay never sent traffic.
  Read `generator-log.jsonl` and `operator-log.jsonl` for the startup error and
  skip to step 4.

### 3. Read the first failing response (do this before anything else)

```bash
jq -s 'map(select(.tags.source == "generator" and .http.res.statusCode >= 400))
  | sort_by(.ts) | .[0]
  | {location, method: .http.req.method, status: .http.res.statusCode, body: .http.res.body, bodyBase64: .http.res.bodyBase64}' \
  "$RPT_DIR/generator-pairs.jsonl"
```

Decode `bodyBase64` if present (`base64 -d`, then `gunzip` if it is
compressed). State in one sentence what the error says before moving on.

No 4xx/5xx does not mean nothing failed. A 201 recorded and 200 replayed is a
failure too. `generator-pairs.jsonl` holds both sides: replayed pairs have
`tags.source == "generator"`, and each carries `tags.refUuid`, the `uuid` of the
recorded pair it replays. The recorded `uuid` is stored as base64 bytes, so
convert it before joining. Do not join on `tags.file` or `tags.sequence`:
`file` is empty in reports, and sequences collide when the snapshot came from
more than one pod. List the status mismatches, oldest first:

```bash
jq -s -c 'def b64uuid:
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/" as $a
    | [explode[] | select(. != 61) | [.] | implode as $c | $a | index($c)]
    | [range(0; length; 4) as $i | .[$i:$i+4]]
    | map((.[0] * 262144 + (.[1] // 0) * 4096 + (.[2] // 0) * 64 + (.[3] // 0)) as $n
          | [($n / 65536 | floor), (($n / 256 | floor) % 256), ($n % 256)])
    | flatten | .[0:16]
    | map("0123456789abcdef" as $h | $h[(. / 16 | floor):(. / 16 | floor) + 1] + $h[(. % 16):(. % 16) + 1])
    | join("") | "\(.[0:8])-\(.[8:12])-\(.[12:16])-\(.[16:20])-\(.[20:32])";
  (map(select(.tags.source != "generator" and .uuid != null)) | map({key: (.uuid | b64uuid), value: .}) | from_entries) as $orig
  | map(select(.tags.source == "generator") | $orig[.tags.refUuid // ""] as $r | select($r != null)
      | select(.http.res.statusCode != $r.http.res.statusCode)
      | {ts, method: .http.req.method, location, recorded: $r.http.res.statusCode, replayed: .http.res.statusCode})
  | sort_by(.ts) | .[0:10][]' "$RPT_DIR/generator-pairs.jsonl"
```

Then read assertion failures (status or body mismatches the analyzer scored):

```bash
jq -s 'sort_by(-.errorCount) | .[0:10] | .[] | {url, assertionType, errorCount, successRate}' "$RPT_DIR/error_summary_table.grpc.jsonl"
```

Load and performance replays keep only a sample of pairs in
`generator-pairs.jsonl` and may drop response bodies
(`tags.responsePayloadDropped: "true"`). For totals, sum the per-interval
`statusCodes` in `summaries.grpc.jsonl`:

```bash
jq -s '[.[].statusCodes | to_entries[]] | group_by(.key) | map({(.[0].key): (map(.value) | add)}) | add' "$RPT_DIR/summaries.grpc.jsonl"
```

Say when a conclusion rests on a sample.

### 4. Investigate in evidence order

Work down this list and stop when the evidence explains the failure.

| # | Evidence | Where |
| --- | --- | --- |
| 1 | First failing response body | `generator-pairs.jsonl` (step 3) |
| 2 | Recorded vs replayed response for the same request | `generator-pairs.jsonl` vs `raw_rr.jsonl`, or the pair in `proxymock/report-<id>/` |
| 3 | Mock match status | `matches.grpc.jsonl` (`cacheStatus`: `MATCH`, `NO_MATCH`, `PASSTHROUGH`), near misses in `similar_sigs.jsonl` |
| 4 | SUT logs | `sut_workload.yaml` for what ran; the app's own logs if the user can fetch them |
| 5 | Transforms and test config | `generator.yaml`, `responder.yaml`, test config `configId` |
| 6 | Infrastructure | `k8s-events.jsonl`, `metric.cpu.grpc.jsonl`, `metric.memory.grpc.jsonl`, `operator-log.jsonl` |

Mock miss triage:

```bash
jq -s 'group_by(.cacheStatus) | map({status: .[0].cacheStatus, count: length})' "$RPT_DIR/matches.grpc.jsonl"
jq -r 'select(.cacheStatus == "NO_MATCH") | [.tech, .command, .location] | @tsv' "$RPT_DIR/matches.grpc.jsonl" | sort | uniq -c | sort -rn | head -20
```

Before blaming signatures, check the missed operation exists in the snapshot
at all. If it does not, the recording is incomplete and the fix is to record
that code path, not to tune mocks. Missed handshake, auth, or session setup
calls explain many downstream misses at once; look at those first.

Signal vs noise: an error that blames something else ("upstream service
error", "transform chain failed", "request timed out") is a symptom. Follow it
to the thing it blames.

## Local run

A local run directory holds the replayed RRPairs as markdown and, for a
standard `proxymock replay`, a `replay-verdict.json`.

### 1. Read the verdict

```bash
RUN=<run directory>
jq '{verdict, mode, baselineDir, summary, gate, goals}' "$RUN/replay-verdict.json"
```

- `verdict: pass`: status and body both matched for every pair. That is a
  real pass, not a status-only one. `mismatch` means at least one pair failed
  on status or body.
- `summary.newMismatches > 0` while requests did not error: the silent
  regression. The service answered, just differently.
- `match: pass` with `bodyMatch: fail` on a pair: right status, wrong field.
  `bodyChanges[]` gives the JSON location.
- With a `baselineDir`, failures with `newMismatch: false` also failed in the
  baseline: the known noise floor. Mention them, do not lead with them.
  Without a baseline, `newMismatch` is always false and every failure counts.
- `goals`: the test config verdict, gated separately from the pair analysis.

List the failing pairs, new ones first (`NEW` and `seen-in-baseline` only
appear when the run had a baseline):

```bash
jq -r '(.baselineDir != null) as $b | .pairs[]
  | select(.match != "pass" or (.bodyMatch // "pass") == "fail")
  | [(if .newMismatch then "NEW" elif $b then "seen-in-baseline" else "fail" end),
     .method, .endpoint, .recordedStatus, .observedStatus, (.bodyMatch // ""), .replayFile] | @tsv' \
  "$RUN/replay-verdict.json" | sort | head -30
```

No `replay-verdict.json` (a recording, a mock run, or an older replay)? Build
the report instead:

```bash
proxymock report --in "$RUN" --format dir --out /tmp/report-$(basename "$RUN")
```

Start from `digest.md`, then `scores.json`, `reliability.json`, and
`fix-prompts/`.

### 2. Read the first failing response

Open the `replayFile` of the first `NEW` pair (it is markdown) and read the
response body, then its `sourceFile` for the recorded one. State the
difference in one sentence before investigating further.

### 3. Investigate

Same evidence order as the cloud path. For mock misses in a local run, read
the mock server's output run (a `mocked-*` directory in the workspace, or
whatever `proxymock mock --out` named): it holds the outbound calls with their
match status.

## Classify and report

Put every failure in exactly one bucket:

| Bucket | Typical evidence | Next step |
| --- | --- | --- |
| SUT regression | first failing body shows an application error or a changed field | point at the endpoint and field; suggest the code path |
| Mock gap | `NO_MATCH` on calls the SUT depends on; operation absent from snapshot | re-record, or tune with `improve-mock-match-rate` |
| Volatile data | only IDs, timestamps, tokens differ | add a blueprint/transform; `proxymock-regression-test` covers masking |
| Environment | 0 generator pairs, connection refused, OOM, pod events | fix the cluster or target, then re-run |
| Test config | goals failing with sane traffic (`<= 0` thresholds, wrong duration) | adjust the goal; say which one and to what |

Reply to the user with:

1. **Verdict** in one line: status, success rate or pair counts, failed goals.
2. **Root cause** with the evidence: the endpoint, the first failing response
   (summarized), and the bucket.
3. **Other findings**, ranked, each with its bucket. Keep noise-floor failures
   last.
4. **Next steps**, concrete and ordered. Offer, do not do, anything that
   changes state: re-running a replay, editing blueprints or test configs,
   pushing to the cloud.

Keep it short. Link report artifacts by path so the user can open them.

## Related skills

- [`improve-mock-match-rate`](../improve-mock-match-rate/SKILL.md): when the answer is "the mocks do not match".
- [`proxymock-compare-results`](../proxymock-compare-results/SKILL.md): compare this run against a known-good one.
- [`proxymock-regression-test`](../proxymock-regression-test/SKILL.md): turn the fix into a baseline-gated regression check.
- [`install-speedscale`](../install-speedscale/SKILL.md): install or sign in to proxymock first.

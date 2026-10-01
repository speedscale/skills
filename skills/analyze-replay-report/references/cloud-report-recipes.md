# Cloud report recipes

The pull, verdict and first-failing-response commands for a cloud report. Read
on demand from `SKILL.md`. Set `WORKSPACE_ROOT` and `RPT_DIR` as shown in step 1.

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

## Mock miss triage

```bash
jq -s 'group_by(.cacheStatus) | map({status: .[0].cacheStatus, count: length})' "$RPT_DIR/matches.grpc.jsonl"
jq -r 'select(.cacheStatus == "NO_MATCH") | [.tech, .command, .location] | @tsv' "$RPT_DIR/matches.grpc.jsonl" | sort | uniq -c | sort -rn | head -20
```

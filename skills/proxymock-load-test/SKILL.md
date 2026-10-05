---
name: proxymock-load-test
description: Run a quick load test by replaying recorded proxymock RRPair traffic at a target with parallel virtual users, then report latency percentiles, throughput, and match rate. Use when users ask for a load test, performance test, stress test, or to push concurrent traffic at a local app or service using recorded proxymock traffic. Start the app with its dependencies mocked first, and read the database caveat below before mocking a database.
argument-hint: --in <recording-dir> --test-against <url> [--vus N | --sessions N | --stage vus=N,for=D] [--for 30s | --times N] [--performance]
---

# proxymock Quick Load Test

Turn a recording into a load test. `proxymock replay` replays recorded requests;
with `--vus` (virtual users) and `--for` or `--times` it becomes a load generator
that reuses traffic the app actually saw, so the load is shaped like production.
It uses local files and the `proxymock` CLI, with no Speedscale Cloud access.

The native command is the whole product:

```bash
proxymock replay --in proxymock/recorded-<name> --test-against http://localhost:8080 \
  --vus 8 --for 30s --load-test --fail-if 'latency.p99>150' --fail-if 'requests.failed!=0'
```

The bundled script `scripts/proxymock-load-test.sh` takes the same flags, adds
`--output json --no-out`, and writes `summary.json` (aggregate and per-endpoint
metrics). Use it when you want that file; otherwise the command above is enough.

## Inputs

- `--in`: the **recording directory** (`proxymock/recorded-<name>`). Replay
  sends only its inbound requests. Do not narrow to `<recording>/localhost`: when
  a database was mapped to localhost, its Postgres or MySQL pairs are written
  there too, next to the inbound ones. If you must narrow, filter inbound pairs
  by direction (`direction: IN` in markdown, `"direction": "IN"` in JSON), not by
  directory.
- `--test-against`: the target (e.g. `http://localhost:8080`). Any part of the
  address you give overrides that part of each recorded request.
- `--vus` (default 4), `--for` / `--times` (default `--for 10s`): flat load.
- `--sessions N`: replay N recorded actors in order at recorded think-time
  (realistic, far lower rps). `--stage vus=N,for=D,ramp=D`: one leg of a ramp,
  repeatable, and not combinable with `--vus`, `--sessions`, `--for` or `--times`.
- `--fail-if`: SLO gate, repeatable, trips exit 1. Metrics:
  `latency.{avg,min,max,p50,p75,p90,p95,p99}`,
  `requests.{total,succeeded,failed,per-second,per-minute,response-pct,result-match-pct}`.
- `--load-test` (script: `--performance`): skip response scoring for maximum
  throughput; `matchPct` is then null and a `--fail-if` on
  `requests.result-match-pct` is refused.

Examples for sessions and ramps: [references/load-shapes.md](references/load-shapes.md).

## Mock the dependencies first

Start the app under `proxymock mock` in one terminal, load it from another. Use
the same `--map` the recording used, with the app pointed at the mapped port:

```bash
proxymock mock --in proxymock/recorded-<name> --map 15432=postgres://localhost:5432 \
  --no-out --app-health-endpoint /healthz -- <app start command>
```

`--no-out` keeps the mock from writing every pair to disk, the biggest mock-side
CPU cost. Without `--map`, the database is not mocked and `mock` will not start
while the real one is up.

**A mocked database cannot measure a database-bound slowdown** (an N+1, a
missing index, a slow query) unless the slow path was itself recorded. A
statement the recording never saw gets a wrong answer or none, the app returns
fast errors, and after a miss the Postgres mock can desync and wedge the pool,
so the load numbers describe the failure, not the slowdown. To measure it:

1. Mock the HTTP dependencies and keep the real database. Pass the **whole
   recording** with its `--map`, and point the app straight at the real
   database:

   ```bash
   DATABASE_URL=postgres://user:pass@localhost:5432/db?sslmode=disable \
   proxymock mock --in proxymock/recorded-<name> --map 15432=postgres://localhost:5432 \
     --no-out --app-health-endpoint /healthz -- <app start command>
   ```

   The `--map` port is then unused; it only keeps `mock` from binding the
   database's own port. Do not narrow `--in` to the HTTP host's directory
   (`<recording>/<host>`): the workspace blueprints do not load from there, so
   their fixes (an ignored `ts` query parameter, say) are not applied and every
   call misses the mock.
2. Load it at the same shape for both builds (or both modes). An app that
   writes to its database changes its own load as it runs: each `POST` adds
   rows the next list query reads. Reset the tables before each run (for
   example `TRUNCATE` the tables the recorded writes touch) and use a fixed
   number of passes (`--times N`) rather than a duration, so both runs see the
   same data and send the same requests.
3. Explain any latency jump by comparing **statements per inbound request**
   between the two runs: record a short run of each under `proxymock record
   --map ...`, run `proxymock-summarize-recording` on both, and divide the
   Postgres pairs by the inbound pairs, then compare each endpoint's statement
   list. A statement whose count scales with the rows returned is an N+1.

## Output

`summary.json` (and the raw `result.json`) carry the aggregate (`-ALL-`) metrics
and a per-endpoint breakdown: `latencyMs` (min, avg, p50, p90, p95, p99, max),
`rps` / `rpm`, `totalRequests`, `succeeded`, `failed`, and `matchPct` (percent of
responses matching the recording; null under `--performance`).

## Interpretation

- **Rising p99 as `--vus` climbs:** the app or a downstream is saturating; step
  `--vus` up (4, 8, 16) to find the knee. **proxymock-perf-container** judges the
  number and refuses to call generator saturation an app limit.
- **Low rps under `--sessions`:** expected. Sessions keep recorded think-time,
  so throughput follows the recorded pacing. Use `--vus` for a ceiling.
- **`failed` above 0:** check the app log. `failed` equal to the VU count, with
  `context canceled` lines at the end of the output, is run teardown on older
  builds, not app failure. On those builds the lines also precede the JSON on
  stdout, so parse from the first `{` line; the script does.
- **`matchPct` low but `failed` 0:** transport success does not establish correctness; responses
  differ from the recording on dynamic fields. Hand off to `tune-snapshot-replay`.

## Result

End with exactly this block:

```
### Result
- **Ran:** what ran, against what
- **Outcome:** pass, fail, or the headline number
- **Numbers:** the 2 to 4 metrics that matter for this skill
- **Artifacts:** paths the run wrote
- **Next:** one suggested next step, naming the skill or giving a prompt
```

For this skill: **Ran** is the recording, the target, whether the database was
mocked or real, and the load shape (`--vus`, `--sessions` or `--stage`, and the
duration). **Outcome** is `pass` or the `--fail-if` that tripped. **Numbers** are
p95 and p99 latency, rps, `failed` count, and `matchPct` (null under
`--performance`). **Artifacts** are the absolute paths of `summary.json` and
`result.json`, if the script ran. **Next** is `proxymock-perf-container` to
judge the number, or `proxymock-regression-test` for correctness.

For saved suites, first qualify correctness and, for SQL workloads, row fidelity, then measure latency, throughput, errors and delivered workload. Use owned local app and mocks with saved limits. Report dependency timing and environment; mocked database numbers do not measure real database capacity. Missing workload delivery or measurements are incomplete or untested, never passed. See [quality-loop](../quality-loop/SKILL.md).

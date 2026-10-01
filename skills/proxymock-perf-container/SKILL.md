---
name: proxymock-perf-container
description: Load-test one service with its downstream mocked by replaying recorded traffic with proxymock replay --vus --for --load-test, and judge the result honestly - how to tell an app limit from test-harness saturation, why cross-run rps comparison on a shared host is meaningless, and which figure survives a move to a sized container. Use when users ask what a container or service can sustain, want load numbers from recorded traffic, or need to know whether a throughput ceiling is the app or the harness.
argument-hint: --in <recording-dir> --test-against <url> --vus N --for D [--load-test]
---

# proxymock Perf Container

Answer "what can THIS container sustain?" for one service in isolation: its
dependencies are mocked, so the numbers describe the service, not them. One
native command:

```bash
proxymock replay --in proxymock/recorded-<name> --test-against http://localhost:8080 \
  --vus 16 --for 30s --load-test
```

**Requires proxymock v2.5.814 or newer.** Judging the result honestly is a
reading skill: that is the rest of this document.

## Isolate the service, then load it

```bash
# 1. app with its dependencies mocked; --no-out keeps the mock's disk writes out of the measurement
proxymock mock --in proxymock/recorded-<name> --map 15432=postgres://localhost:5432 \
  --no-out --app-health-endpoint /healthz -- <your app command>

# 2. load it, optionally with an SLO gate (exit 1 when a threshold trips)
proxymock replay --in proxymock/recorded-<name> --test-against http://localhost:8080 \
  --vus 16 --for 30s --load-test --fail-if "latency.p99 > 50" --fail-if "requests.failed != 0"
```

- **Include `--map`** whenever the app has a database, with the app pointed at the
  mapped port (as in [`record-traffic`](../record-traffic/SKILL.md)); otherwise
  the database is not mocked and `mock` will not start while the real one is up.
- **Pass the recording root to `--in`** on the replay side. Replay sends only
  the inbound requests; `<recording>/localhost` also holds database pairs when a
  database was mapped to localhost.
- **A mocked database hides a database-bound slowdown** (N+1, missing index)
  unless the slow path was recorded. Measure it with the HTTP dependencies
  mocked and the real database, and explain any latency jump by comparing
  statements per inbound request between two runs. The recipe is in
  [`proxymock-load-test`](../proxymock-load-test/SKILL.md#mock-the-dependencies-first).
- Shapes beyond a flat `--vus` level (`--sessions`, `--stage`) are covered there.
  A flat level is what a capacity ladder needs, because rungs must be comparable.

`--load-test` disables response scoring, so `requests.result-match-pct` is not
reported and this run says nothing about correctness; that is
**proxymock-regression-test**'s job. Drop `--load-test` to get match rates back.

## Judging the number honestly

The load generator and the app usually share a host, and the generator can
saturate it well before an efficient app does, with zero failed requests the
whole way, so a naive report calls host saturation an app limit.

**As of proxymock v2.5.824 the binary does this for you.** Load runs sample
generator, mock and app CPU, print the shares, and mark a run `HARNESS-BOUND`
when host idle falls below 20%, or harness CPU (generator + mock) is at least a
full core and more than 2x the app's. Harness-bound throughput is a floor, not
the app's ceiling. Read the marking, quote the CPU shares next to it, and do not
quote an app ceiling from a harness-bound level: rerun from a separate load host
or the Kubernetes generator if the answer matters. On older builds, apply the
same two rules by hand (counting the mock as harness, see the reference).

**Check the marking against the shares.** An app that spends its time waiting on
a database uses little CPU, so "harness CPU above 2x the app's" can fire on a
host that is mostly idle. Say plainly what happened ("the mock used 2.2x the
app's CPU, host 76% idle"), and trust host idle for saturation.

## Reading the result (details in the reference)

- **Compare only within one run**, or within one session on one host. Repeat
  samples at a fixed VU level spread about 1%; the same level on separate runs
  on a contended host measured 27% apart.
- **Quote efficiency, not raw rps.** rps per app-core survives a move to a sized
  container; a raw ceiling is a fact about this host.
- **p99 with dependencies mocked is the service's own overhead**, not a
  production latency. Percentiles are integer milliseconds, so sub-5 ms deltas
  are rounding.
- **`failed` above 0:** check the app log first. `failed` equal to the VU count
  with `context canceled` lines is teardown on older builds, not app failure.
- **Find the knee** with an ascending ladder (`1,4,16,50`): the first level whose
  rps gain is under about 10% is the plateau, and the level before it is the
  sustainable figure. Exclude harness-bound levels.

Measurements and the ladder method:
[references/reading-results.md](references/reading-results.md).

## Related

- **proxymock-load-test**: the flat-load skill with `--fail-if` SLO gates and
  an optional script that writes `summary.json`.
- **proxymock-regression-test**: the correctness gate over the same recording.
  Run it before trusting perf numbers from a build that may have behavior
  regressions.
- **proxymock-chaos-mock**: drive this load while the downstream is slow or
  flaky.

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

For this skill: **Ran** is the VU level or ladder against the service with its
dependencies mocked (database mocked or real). **Outcome** is the sustainable throughput and whether the run
was `HARNESS-BOUND` (then a floor, not a ceiling). **Numbers** are rps, rps per
app-core, p95 and p99 latency, and `failed`. **Artifacts** are the replay output
or result files. **Next** is `proxymock-regression-test` to check correctness
of the same build, or a re-run from a separate load host if harness-bound.

---
name: proxymock-regression-test
description: Run a regression test from a proxymock recording. Starts the app with its dependencies mocked, replays the recording at it, and gates on the per-RRPair verdict (response status AND body) plus baseline-relative new mismatches, or on a tuned test config's goals, catching status-code and field-level regressions that a clean requests.failed hides. Also creates the first regression gate for a service from one recording. Use when users ask to regression-test a service against recorded traffic, verify a code change did not break behavior, make a regression gate for their own service, or gate CI on a proxymock replay. A service that runs as a Kubernetes workload goes to run-snapshot-replay in cluster mode with the regression mode.
argument-hint: --in <recording-dir> --test-against <url> [--baseline <prior-replay-dir>] [--test-config <name>]
---

# proxymock Regression Test

Turn a recording into a regression gate. One native command does it:

```bash
proxymock replay \
  --in proxymock/recorded-<name> \
  --test-against http://localhost:8080 \
  --baseline proxymock/results/regress-base \
  --fail-on-new-mismatch
```

`replay` drives every recorded request at the target, scores each response
against the recording (status **and** body), writes `<out>/replay-verdict.json`,
and exits. Nothing in this repo re-derives that answer. Terms (verdict,
accuracy, passAssertPct, match rate) are defined in
[`quality-loop`](../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill).

**Requires proxymock v2.5.814 or newer.**

## In a Kubernetes cluster

When the service under test is a cluster workload, the replay runs there:
use [`run-snapshot-replay`](../run-snapshot-replay/SKILL.md) in cluster mode
with the **regression** mode. It stages the recording, the workspace's
blueprints and the tuned test config through the kubeconfig and runs:

```bash
proxymock cluster replay start --in proxymock/recorded-<name> \
  -n <namespace> --workload <workload> --snapshot-source local \
  --test-config <name> --wait
```

The test config's goals are the gate (`passAssertPct >= 100` in the built-in
`regression`), and the command exits nonzero on a miss, so CI can run it as
is. There is no `--baseline` in a cluster: tune the tests first so a clean run
passes. Report it with the result block below.

## 1. Start the app under test, mocked

The replay needs the app running with its dependencies answered from the same
recording. Reuse **every** `--map` the recording used (see
[`record-traffic`](../record-traffic/SKILL.md)), or the database is not mocked
and `mock` refuses to start while the real one is up:

```bash
proxymock mock --in proxymock/recorded-<name> \
  --map 15432=postgres://localhost:5432 --app-health-endpoint /healthz \
  --out proxymock/results/mocked-<ts> -- <app run command>
```

Run the replay in another terminal against the app's own port. Tune the tests
([`tune-snapshot-replay`](../tune-snapshot-replay/SKILL.md)) and the mocks
([`improve-mock-match-rate`](../improve-mock-match-rate/SKILL.md)) first, so a
clean baseline is real and not just quiet.

## 2. Establish the baseline, then gate

Write every run under `proxymock/results/`, not the repo root, so `doctor` and
`mock --in .` do not mistake a run for a recording.

```bash
# first run, on known-good code
proxymock replay --in proxymock/recorded-<name> --test-against http://localhost:8080 \
  --out proxymock/results/regress-base [--test-config <name>]

# every run after, on the changed code
proxymock replay --in proxymock/recorded-<name> --test-against http://localhost:8080 \
  --out proxymock/results/regress-run --baseline proxymock/results/regress-base \
  --fail-on-new-mismatch [--test-config <name>]
```

`--fail-on-new-mismatch` is rejected without `--baseline`. The same command runs
in any CI (k6, bruno, pytest, Make); `quality-loop.sh regression` only prints it.

## Which scorer decides the exit code

- **No `--test-config`:** the verdict decides. `0` pass, `3` a pair fails now
  that did not fail in `--baseline`, `1` the run did not complete or a
  `--fail-if` tripped.
- **With `--test-config <name>`:** the config's goals decide (usually
  `passAssertPct >= 100`). The run exits `1` on a missed goal, and `3` when a
  baseline gate also finds a new mismatch, while `replay-verdict.json` can still
  say `pass`. Use the config the user tuned in `tune-snapshot-replay`
  (`proxymock/testconfigs/<name>.json`) for the baseline **and** every later run,
  so both sides are scored the same way.

Say which scorer failed when you report. The output names the failing goal or
the `NEW MISMATCH` lines.

## Read the verdict, never the transport metrics

`requests.failed` stays **0** for a status regression: a 201 that becomes a 200
completes the exchange perfectly. Gate on the exit code and the verdict file.

**Body scoring is native and on by default.** Each pair carries `bodyMatch` and
`bodyChanges[]` of `{severity, kind, endpoint, location, baseline, candidate}`
with `kind` `value_changed`, `field_added` or `field_removed`. Newer proxymock
also reports a JSON type change (a number that becomes a string) as
`type_changed`. On older builds that change scores as a body match, so add a
body-asserting test config (`httpResponseBody`) to catch it. Pass
`--ignore-body-changes` for status-only scoring when status and headers are the
whole contract.

## Caveats and blueprints

- **Baseline masking compares change sets.** A pair that failed in the baseline
  is exempt from *that same failure* only; a different failure on it exits 3.
- **Volatile-value suppression follows value patterns**, not field names: UUID
  and timestamp values are ignored, other varying values are scored. Never trust
  a raw `bodyMismatches: 0`; gate on NEW mismatches against a baseline.
- **An app with moving IDs needs a blueprint**, or its auth and moving-ID
  endpoints fail before and after a change and a regression there is
  undetectable. Confirm the `Loaded blueprint "<name>" from <path>` line, and
  never filter a blueprint on `network_address` (it goes inert, silently, when
  `--test-against` is spelled differently). Use `detectedLocation` and scope with
  `services`.

Details and the `--require-blueprint` trade-off:
[references/blueprints-and-caveats.md](references/blueprints-and-caveats.md).

## Interpretation

- **`NEW MISMATCH` with `requests.failed` 0** is the classic silent regression,
  printed as `NEW MISMATCH: POST /orders recorded 201 -> observed 200`, or for a
  body-only change `... status 200, body total removed (was 24)`.
- **Verdict `pass`, exit 0:** status and body both matched, with the caveats
  above (type changes on older builds). When a run fails, read which pair
  tripped it: an incidental field can be the only thing that changed.
- **`match: pass` with `bodyMatch: fail`:** right status, wrong field. Read
  `bodyChanges[]` for the JSON location.
- **Failures present but none new:** the known noise floor. Read them anyway
  when the baseline was noisy.
- **A service with no spec**: its contract IS the recording. Spec conformance
  for the chosen app or dependency boundary goes to `proxymock-contract-test`.

For a saved suite, use [quality-loop](../quality-loop/SKILL.md). Keep recording baselines as candidates until a developer accepts the expectation revision; skills and CI must not update acceptance or loosen assertions after a failure.

## Related

- **record-traffic** makes the recording; **proxymock-verify-fix** is the
  inverted twin over an incident capture; **proxymock-compare-results** compares
  two run directories in depth; **proxymock-perf-container** runs the same replay
  under load.

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

For this skill: **Ran** is the recording, the target, the test config if any,
and whether a baseline was used. **Outcome** is the verdict (`pass`,
`new-mismatch`, or a baseline established) and which scorer decided the exit
code. **Numbers** are pairs replayed, new mismatches, body mismatches,
`passAssertPct` when a test config ran, and `requests.failed`. **Artifacts** are
the `--out` directories and `replay-verdict.json`. **Next** is usually a CI line
for the gate, or `proxymock-load-test` for the performance check.

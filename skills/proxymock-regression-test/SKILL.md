---
name: proxymock-regression-test
description: Replay a recorded proxymock session against a target and gate on the per-RRPair replay verdict (response status AND body) plus baseline-relative new mismatches, catching status-code and field-level regressions that a clean requests.failed hides. Use when users ask to regression-test a service against recorded traffic, verify a code change did not break replay behavior, or gate CI on a proxymock replay.
argument-hint: --in <recording-dir> --test-against <url> [--baseline <prior-replay-dir>]
---

# proxymock Regression Test

Turn a recording into a regression gate. One native command does it:

```bash
proxymock replay \
  --in ./proxymock/recording \
  --test-against http://localhost:8080 \
  --baseline ./regress-base \
  --fail-on-new-mismatch
```

That is the whole gate. `replay` drives every recorded request at the target, scores each response against the recording (status **and** body), writes `<out>/replay-verdict.json`, and exits on the verdict. Use that native verdict directly.

**Requires proxymock v2.5.814 or newer.** Everything below was measured on that
release.

## Works with your stack (no bash required)

The command above is the contract. It takes a directory of RRPair files and a
URL, so it does not care what language your service is in, what test framework
you use, or whether you own a shell script. A k6, bruno, postman-cli, pytest,
JUnit, or plain-Makefile user runs exactly the same line in CI:

```bash
# first run, establish the baseline
proxymock replay --in ./proxymock/recording --test-against http://localhost:8080 \
  --out ./regress-base

# every run after, gate against it
proxymock replay --in ./proxymock/recording --test-against http://localhost:8080 \
  --out ./regress-run --baseline ./regress-base --fail-on-new-mismatch
```

Exit codes are the CI contract:

| Exit | Meaning |
| --- | --- |
| `0` | verdict `pass` (or findings present but no `--fail-on-new-mismatch`) |
| `3` | verdict `new-mismatch`: a pair fails now that did not fail in `--baseline` |
| `1` | the run did not complete, or a `--fail-if` threshold tripped |

`--fail-on-new-mismatch` is rejected without `--baseline`; establish a baseline first. The optional `quality-loop.sh regression` is optional convenience that builds this exact line and passes the exit code through; the native command is what you should put in your pipeline.

## Read the verdict, never the transport metrics

`requests.failed` stays **0** for a status regression. A 201 that becomes a 200
completes the HTTP exchange perfectly, so the transport counter is clean while
the pair is scored a mismatch. Gate on the verdict file and the exit code.
Empirically verified.

**Body scoring is native and on by default.** Each pair in
`replay-verdict.json` carries `bodyMatch` and a `bodyChanges[]` list of
`{severity, kind, endpoint, location, baseline, candidate}`, `kind` being
`value_changed` / `field_added` / `field_removed`. Measured: `/api/stats`
returning `total: 25` where the recording says `24`, with an unchanged 200,
scores `match: pass` but `bodyMatch: fail` at
`http.res.bodyBase64.total` and trips the gate (exit 3). Pass
`--ignore-body-changes` to go back to status-only scoring when status and
headers really are the whole contract.

## Two measured caveats on the gate

**Baseline masking compares CHANGE SETS, not just pairs.** A pair that already
failed in the baseline is exempt from *that same failure*, not from every later
one. Verified both ways: an identical failure stays masked and the run exits 0;
the same pair failing *differently* (401 that starts returning 500, or a body
change at a location the baseline did not fail at) is caught as a new mismatch
and exits 3.

**Volatile suppression is by FIELD NAME, it is undocumented, and it is not stable.** For example, measurements on a test fixture found that `Date` headers, bare 64-hex tokens, the `order_id` field (suppressed whatever the replacement value looks like) and the ISO-8601 `created` timestamp are suppressed, while `status`, `project`, `total` and `expires_in` changes on the same pairs are scored. A later round measured the opposite for a live `order-<16hex>`. So treat a raw `bodyMismatches: 0` as luck: establish a `--baseline` and gate on NEW mismatches. That is what keeps the gate green on a recording whose app mints fresh values every run.

## Blueprints: the part that silently costs you the signal

An app with moving IDs (rotating tokens, generated order ids) needs a blueprint
to chain them through the replay. Without one, the auth and moving-ID endpoints
401, and **a regression on their success paths is undetectable** because they
fail before and after the change.

- **Keep blueprints in the app workspace.** Put chains in `proxymock/blueprints/`, alongside that app's recording directories. Point `--in` at the user's recording and check the `Loaded blueprint "<name>" from <path>` line and transform-chain summary. Keep the standard workspace layout rather than copying blueprints inside the RRPair directory.
- **The hostname trap (this one costs you the whole run).** Replay rewrites the recorded network address to the `--test-against` target, so a blueprint that filters on `network_address` binds itself to one spelling of that target. For example, a blueprint that filters `network_address CONTAINS "localhost"`: `--test-against localhost:8080` fired both chains (2 replayed RRPairs carrying `smart_replace`), while `--test-against 127.0.0.1:8080` **loaded the blueprint and fired ZERO chains, with no warning**. Same `Loaded blueprint` line either way. A loaded-but-inert blueprint is usually this, not a staging problem. Filter on `detectedLocation` / `detectedCommand` and scope with `services`.
- **`--require-blueprint <name>` works, and is opt-in for a reason.** On v2.5.814 it exits 0 and still writes `replay-verdict.json` when the blueprint loaded and its chains ran; on an unresolvable name it exits 1 and writes **no verdict file at all**. Gating on it trades the entire regression signal for a blueprint warning. Add it when a silently inert blueprint is the bigger risk; otherwise check the `Loaded blueprint` line and grep the replay output for `smart_replace`.

## Interpretation

- **`NEW MISMATCH` with `requests.failed` 0**: the classic silent regression. Printed as `NEW MISMATCH: POST /api/orders recorded 201 -> observed 200`, and body-only findings as `... status 200, body total removed (was 24)`.
- **Verdict `pass`, exit 0**: status and body both matched. A real clean bill of health now that bodies are scored, not a status-only one.
- **`match: pass` with `bodyMatch: fail`**: right status, wrong field. Read `bodyChanges[]` for the JSON location.
- **Failures present but none new**: the known noise floor from the user's comparison baseline. Inspect those failures before accepting them as harmless; a baseline is not evidence that the original behavior was correct.
- **Known-mismatch pairs**: masked only against the failure they showed in the baseline. Read them anyway when the baseline was noisy; a pair can be failing in a way the volatile heuristic owns.
- **An app without an inbound API spec**: use the recording as the behavior contract. Route dependency spec conformance to proxymock-contract-test; route the app's recorded behavior here.

## Related

- **proxymock-verify-fix**: the inverted twin, over an incident capture.
- **proxymock-compare-results**: deep report and drift comparison of two replay
  output dirs.
- **proxymock-perf-container**: the same replay under load.

---
name: analyze-replay-report
description: "Analyze a Speedscale or proxymock replay report and explain what happened, why it failed or passed, and what to do next. Use when the user pastes a report ID or a proxymock run directory, or asks \"analyze this report\", \"why did this replay fail\", \"what does this report mean\", \"Missed Goals\", \"NO_MATCH\", or \"low success rate\". Works on cloud reports (pulled with proxymock) and on local proxymock replay runs (replay-verdict.json). Read-only: it never re-runs a replay or changes config without asking."
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

| Input | Looks like | Go to |
| --- | --- | --- |
| Cloud report ID | a UUID, often with a host such as `app.speedscale.com` | [Cloud report](#cloud-report) |
| Local run directory | a path under a proxymock workspace, e.g. `proxymock/results/replayed-3`, `proxymock/report-<uuid>` | [Local run](#local-run) |

A `report-<uuid>` directory is an already-pulled cloud report: use the UUID.

## Prerequisites

- `proxymock` on PATH and signed in (`proxymock cloud pull` needs an API key
  for cloud reports; local runs need no account).
- `jq` for the one-liners below.

If proxymock is missing or not signed in, use
[`install-speedscale`](../install-speedscale/SKILL.md) first (CLI and auth only).
For a host other than `app.speedscale.com`, pass `--app-url <host>`. Never print
the API key or secret-bearing bodies.

## Cloud report

### 1-3. Pull it, read the verdict, read the first failing response

Run the commands in
[references/cloud-report-recipes.md](references/cloud-report-recipes.md). The
shape of it:

1. `proxymock cloud pull report <report-id>` from the workspace root. It gives
   `RPT_DIR` (raw artifacts, metadata in `$RPT_DIR.json`) and
   `proxymock/report-<report-id>/` (one markdown file per request). An auth or
   tenant error means the report belongs to another tenant: say so and do not
   retry with other credentials.
2. Read `status` (`Passed`, `Missed Goals`, `Error`), `successRate` and every
   `FAIL` goal from `$RPT_DIR.json`. An empty `generator-pairs.jsonl` means the
   replay never sent traffic: read `generator-log.jsonl` and `operator-log.jsonl`,
   then go to step 4.
3. **Read the first failing response before anything else.** The recipe gives
   the first 4xx/5xx generator pair, a join of replayed against recorded pairs
   for silent status mismatches (a 201 recorded and 200 replayed is a failure
   too), and the analyzer's assertion failures. Load replays keep only a
   sample of pairs; say when a conclusion rests on one.

### 4. Investigate in evidence order

Work down this list and stop when the evidence explains the failure.

| # | Evidence | Where |
| --- | --- | --- |
| 1 | First failing response body | `generator-pairs.jsonl` (step 3) |
| 2 | Recorded vs replayed response for the same request | `generator-pairs.jsonl` vs `raw_rr.jsonl`, or the pair in `proxymock/report-<id>/` |
| 3 | Mock match status | `matches.grpc.jsonl` (`cacheStatus`: `MATCH` (a HIT), `NO_MATCH` (a MISS), `PASSTHROUGH`), near misses in `similar_sigs.jsonl` |
| 4 | SUT logs | `sut_workload.yaml` for what ran; the app's own logs if the user can fetch them |
| 5 | Transforms and test config | `generator.yaml`, `responder.yaml`, test config `configId` |
| 6 | Infrastructure | `k8s-events.jsonl`, `metric.cpu.grpc.jsonl`, `metric.memory.grpc.jsonl`, `operator-log.jsonl` |

Mock miss triage commands are in [references/cloud-report-recipes.md](references/cloud-report-recipes.md#mock-miss-triage).

Before blaming signatures, check the missed operation exists in the snapshot; if
not, record that code path. Missed handshake, auth or session calls explain many
downstream misses at once. An error that blames something else ("upstream service
error", "request timed out") is a symptom: follow it to what it blames.

## Local run

A local run directory holds the replayed RRPairs and, for a `proxymock replay`,
a `replay-verdict.json`.

### 1. Read the verdict

```bash
RUN=<run directory>
jq '{verdict, mode, baselineDir, summary, gate, goals}' "$RUN/replay-verdict.json"
```

- `verdict: pass`: status and body matched for every pair, a real pass.
  `mismatch`: at least one pair failed on status or body.
- `summary.newMismatches > 0` with no request errors: the silent regression.
- `match: pass` with `bodyMatch: fail`: right status, wrong field;
  `bodyChanges[]` gives the JSON location.
- With a `baselineDir`, `newMismatch: false` failures also failed in the
  baseline (the noise floor): mention, do not lead. Without a baseline every
  failure counts.
- `goals`: the test config verdict, gated separately.

List the failing pairs, new ones first, with the recipe in
[references/local-run-recipes.md](references/local-run-recipes.md). No
`replay-verdict.json` (a recording, a mock run, an older replay)? Build a report
from the same file: `proxymock report --in "$RUN" --format dir`, then start from
`digest.md`.

### 2. Read the first failing response

Open the `replayFile` of the first `NEW` pair (it is markdown) and read the
response body, then its `sourceFile` for the recorded one. State the
difference in one sentence before investigating further.

### 3. Investigate

Same evidence order as the cloud path. For mock misses in a local run, read
the mock server's output run (a `mocked-*` directory under
`proxymock/results/`, or whatever `proxymock mock --out` named): it holds the
outbound calls with their match status, and `proxymock replay score <run>
[--mock-run <mock run>] -o json` gives the measured match rate and passthrough
count. Terms: [`quality-loop`](../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill).

## Classify and report

Put every failure in exactly one bucket:

| Bucket | Typical evidence | Next step |
| --- | --- | --- |
| SUT regression | first failing body shows an application error or a changed field | point at the endpoint and field; suggest the code path |
| Mock gap | `NO_MATCH` (MISS) or `PASSTHROUGH` on calls the SUT depends on; operation absent from snapshot | re-record, or tune with `improve-mock-match-rate` |
| Volatile data | only IDs, timestamps, tokens differ | tune the tests with `tune-snapshot-replay` (transform or assertion exclusion) |
| Environment | 0 generator pairs, connection refused, OOM, pod events | fix the cluster or target, then re-run |
| Test config | goals failing with sane traffic (`<= 0` thresholds, wrong duration) | adjust the goal; say which one and to what |

Reply with the classified findings, ranked, noise-floor failures last. Offer,
do not do, anything that changes state: re-running a replay, editing blueprints
or test configs, pushing to the cloud. Then end with exactly this block:

```
### Result
- **Ran:** what ran, against what
- **Outcome:** pass, fail, or the headline number
- **Numbers:** the 2 to 4 metrics that matter for this skill
- **Artifacts:** paths the run wrote
- **Next:** one suggested next step, naming the skill or giving a prompt
```

For this skill: **Ran** is the report or run directory analyzed. **Outcome** is
the verdict and the root-cause bucket. **Numbers** are success rate or pair
counts, failed goals, new mismatches, and mock MISS and PASSTHROUGH calls.
**Artifacts** are the report paths the evidence came from. **Next** is the skill
for the bucket: `tune-snapshot-replay` (volatile data or accuracy),
`improve-mock-match-rate` (mock gap), or a code fix (SUT regression).

Related: `proxymock-compare-results`, `proxymock-regression-test`.

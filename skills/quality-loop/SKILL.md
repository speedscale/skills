---
name: quality-loop
description: The entry point for testing a service with recorded traffic using proxymock. Routes an intent to the right skill (record, run a replay, tune the tests, tune the mocks, regression gate, load test, verify a fix, chaos, contract, compare), defines the shared terms (HIT/MISS/PASSTHROUGH, match rate, accuracy, verdict), walks the "do it to my own service" flow, and includes a doctor that checks the environment. Use when users ask to turn a recording into saved scenarios, improve OpenAPI coverage or NFR checks, or how to test a change with recorded traffic, which proxymock skill or command applies, to set up the loop in a repo, to test their own service, or whether the environment is ready.
argument-hint: <doctor|regression|verify-fix|load|chaos|contract|compare|summarize|load-test> [args...]
---

# proxymock Quality Loop

The loop: record real traffic once, keep it as a snapshot (RRPair files), run your code against the snapshot, act on the diff. One recording feeds the regression gate, dependency mocks, load workload and chaos cases. Coverage expansion may require supplemental capture from owned dependencies; a small recording cannot establish every business outcome.

**Recording-to-scenarios requires a recent proxymock build.** Verify `coverage --help`, `replay score --help`, `mock --help` for `--chaos`, and `generate --help` for `--direction` before starting. The doctor's v2.5.814 check is a legacy workflow baseline, not proof that these newer features exist. Save the installed version with results; do not infer feature availability from that old version gate.

## Recording to saved scenarios

For “turn this small recording into regression, contract, load and chaos tests” or “improve OpenAPI coverage and NFR scenarios,” read [the recording-to-scenarios workflow](references/recording-to-scenarios.md). Compose the specialist skills through this entry point. Native product features execute and score tests; the agent proposes cases and carries setup/evidence between skills. Mocks are the reusable dependencies that make repeated and concurrent runs possible. Complete each requested scenario type and retain unresolved prerequisites while independent scenarios run.

Start the mock-lab demonstration with its existing languages/go HTTP app and committed recording. Keep first-run setup to the language runtime and proxymock; use native commands and the existing harness. Databases, Docker and additional services belong to apps that already require them.

## Routing

| Intent sounds like | Skill |
| --- | --- |
| "Turn this recording into scenarios", "fill coverage gaps", "deepen NFR tests" | **quality-loop**, [recording-to-scenarios workflow](references/recording-to-scenarios.md) |
| "Record traffic", "I need a recording" | **record-traffic** |
| "What is in this recording?" | **proxymock-summarize-recording** |
| "Run this recording or snapshot", replay it locally or in the cluster | **run-snapshot-replay** |
| "Install Speedscale", "set up the operator" | **install-speedscale** |
| "Replayed responses differ", "get the replay to pass", tests fail on IDs, timestamps, tokens | **tune-snapshot-replay** (the tests) |
| Mock misses, `MISS`, passthrough, low match rate, any protocol | **improve-mock-match-rate** (the mocks) |
| "Did my change break anything?", CI gate | **proxymock-regression-test** |
| "What can this service sustain?", load numbers, SLO gates | **proxymock-load-test**, and **proxymock-perf-container** to judge the number |
| "Prod incident: reproduce it and prove the fix" | **proxymock-verify-fix** |
| "How does it behave when the downstream misbehaves?" | **proxymock-chaos-mock** |
| "Does my dependency match its spec?" | **proxymock-contract-test** |
| "What changed between these two runs?" | **proxymock-compare-results** |
| "Why did this report fail?" | **analyze-replay-report** |

Tie-breakers:

- **Tests vs mocks** is decided by which side is wrong. Responses from the app
  differ from the recording: `tune-snapshot-replay`. The app's outbound calls
  are not answered by the mocks: `improve-mock-match-rate`. Each owns its side
  and hands the other side over.
- **regression vs verify-fix** is decided by the recording. A healthy recording
  plus "did I break it" is `regression`. An incident capture (recorded errors
  are the truth) plus "is it fixed" is `verify-fix`.
- **contract vs regression** is decided by the boundary. A boundary with an accepted OpenAPI schema uses `contract`, including your own inbound API. Recorded journeys and accepted business outcomes use `regression`; both apply to the same app.
- **regression vs run-snapshot-replay** is decided by the target. A local app at
  a known URL that must pass a gate is `regression`. A snapshot to run where it
  was recorded, often a cluster workload, is `run-snapshot-replay`. A regression
  gate or load test on a cluster workload is `run-snapshot-replay` too, in its
  regression or load mode; `regression` and `load-test` hand it over.

## Terms (used the same way in every skill)

| Term | Meaning |
| --- | --- |
| **HIT / MISS / PASSTHROUGH** | What a mock did with one outbound call. HIT: a recorded request matched and the mock answered. MISS: the mock covers that host but no recorded request matched (older output and cloud reports say `NO_MATCH`; a HIT was `MATCH`). PASSTHROUGH: nothing mocked it, so it reached the real service. |
| **Match rate** | HIT / (HIT + MISS + PASSTHROUGH). Three flavors: **measured** is counted from a real run of the app behind the mock (`proxymock replay score`, `matchRate.rate`); **projected** is the offline estimate after a blueprint edit, before any re-run; **report** is the analysis's rate from replaying the recording's own outbound requests at the mock, which is a ceiling and can read 100% while the live app's measured rate is lower. Quote measured when you have it. |
| **Accuracy** | Share of replayed pairs whose response matched the recorded one, scored by proxymock's built-in status and body rules (`accuracy.rate`). |
| **passAssertPct** | Percent of test-config assertions that passed. It exists only when a `--test-config` with assertions ran, and is stricter than accuracy: the built-in `standard` config asserts headers and cookies too. |
| **Verdict** | `replay-verdict.json`: the per-pair pass or mismatch result of the built-in scoring, plus new mismatches against a `--baseline`. |
| **Exit code** | Without `--test-config`, the verdict decides it. With one, that config's goals (usually `passAssertPct >= 100`) decide it, and the verdict can say pass while the run exits nonzero. |

## Do it to your own service

The flow for "set this up for my service". Do each step with its skill, and stop
to report if one fails.

First ask once, unless the user already said: **does the service run on this
machine, or in a Kubernetes cluster?** The answer picks the mode of every step
below; do not ask again per step.

- **On this machine:** the steps as written.
- **In a cluster:** the Speedscale operator has to be there first
  ([`install-speedscale`](../install-speedscale/SKILL.md)). Record with
  `record-traffic` in its cluster mode, then make the replay trustworthy and
  gate it with `run-snapshot-replay` in cluster mode (regression mode). Tuning
  (`tune-snapshot-replay`, `improve-mock-match-rate`) works on the pulled
  recording on this machine; its blueprints and test configs travel with the
  next cluster replay. Use the kube context the user named, never another.

1. **Read the repo.** Find the run command, the port, the outbound HTTP hosts and
   any databases, and how the project already generates traffic. Run
   `scripts/quality-loop.sh doctor` to check proxymock, ports and Node support.
2. **Record one run** with [`record-traffic`](../record-traffic/SKILL.md).
   Local first. Stop only when inbound traffic and every outbound host and
   database are in the recording. Wait for the app on its own port (or with
   `--app-health-endpoint`), never through proxymock's inbound port 4143,
   which records every request it sees.
3. **Make the replay trustworthy.** Replay it once
   ([`run-snapshot-replay`](../run-snapshot-replay/SKILL.md)). If responses
   differ on IDs or timestamps, run `tune-snapshot-replay`; if mocks miss, run
   `improve-mock-match-rate`.
4. **Produce a first regression gate** with
   [`proxymock-regression-test`](../proxymock-regression-test/SKILL.md): app
   under mocks, baseline replay on the current code, then the gated command CI
   can run. Commit the recording, blueprints and test configs only after
   checking they hold no secrets.
5. **Offer the next tier**: a load test (`proxymock-load-test` locally, or
   `run-snapshot-replay` in load mode in a cluster), or a chaos run.

Where things live: recordings in `proxymock/recorded-<name>/`; every replay and
mock run in `proxymock/results/<name>/`; tuning state in `proxymock/blueprints/`,
`proxymock/testconfigs/` and `proxymock/tuning/`. Only files under the
workspace's `proxymock/` apply to a local run: nothing under `~/.speedscale` is
applied to a local replay.

## Reference

[references/gotchas.md](references/gotchas.md) holds the native command for each
intent (exit codes are the CI contract), the gotchas that apply on several
routes, and the dispatcher and `doctor` usage. Read it when a result surprises
you.

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

For this skill: **Ran** is the flow and steps completed (or the `doctor` run).
**Outcome** is `ready`, `gate created`, or the step that stopped. **Numbers** are
pairs recorded, replay accuracy or measured match rate, and the gate's baseline
verdict. **Artifacts** are the recording, baseline and gate command. **Next** is
the next tier, or the skill for the step that failed.

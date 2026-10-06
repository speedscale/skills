---
name: tune-snapshot-replay
description: Iteratively tune the TESTS of a Speedscale snapshot or proxymock recording until its replay is accurate, in a persistent loop that re-runs the replay (locally or in the cloud), measures, changes one thing, and keeps or reverts. Owns test accuracy - replayed responses that differ from the recording (expired credentials, IDs created during the session, stateful environments, legitimately volatile fields like timestamps), transforms, test config and assertions. Any mock problem (MISS, passthrough, low match rate) is handed to improve-mock-match-rate. Use when the user asks to "tune this snapshot", "tune the tests", "get this replay to pass", "raise replay accuracy", "the replay keeps failing, fix it", or wants a Ralph Wiggum style loop on a replay.
argument-hint: <snapshot-id | report-id | recording-dir> [--local | --cloud] [--target-accuracy 95] [--max-runs N]
---

# Tune a snapshot replay (test accuracy)

Make a replay's **answers** trustworthy: replayed responses match what was
recorded, except for fields that legitimately vary. This skill owns the test
side: response diffs, transforms, test config and assertions. It does **not**
tune mocks: when outbound calls are not answered (`MISS`, `PASSTHROUGH`, low
match rate), hand that to
[`improve-mock-match-rate`](../improve-mock-match-rate/SKILL.md) and come back.
Terms (accuracy, passAssertPct, match rate) are defined in
[`quality-loop`](../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill).

The rule that matters most: **a real application failure is a finding, not
noise.** If the service under test (SUT) answers differently because of a code
change, report it. Never mask, ignore or transform it away to raise the score.

## Inputs

| Input | Meaning |
| --- | --- |
| Snapshot ID, report ID, or recording directory | what to tune; a report ID also gives you a first run |
| `--local` / `--cluster` / `--cloud` | where to run; default is where it was recorded |
| `--target-accuracy` | default 95 (% of replayed pairs matching) |
| `--max-runs` | re-run budget; default 5 in the cloud, 10 locally |

Confirm the budget once for cloud runs (each pushes a snapshot and uses cluster
capacity). Ask before any production-looking namespace.

**A workload replayed through the kubeconfig (`--cluster`)** reports a verdict
and its goals, not per-pair results, so this loop cannot score it. Pull the
recording (`record-traffic` cluster mode), iterate locally with the app behind
the mock, then confirm once with
[`run-snapshot-replay`](../run-snapshot-replay/SKILL.md) in cluster mode with
`--test-config <name>`: the workspace's blueprints and test config travel with
that replay.

## Prerequisites

- **Local loop:** `proxymock` and `jq` on PATH. No login. Use the **Local mode**
  section of [`run-snapshot-replay`](../run-snapshot-replay/SKILL.md) for the
  run steps and skip its cloud parts.
- **Cloud loop:** also `speedctl` signed in, and that skill's cloud reference.
- Never print API keys or paste recorded bodies holding secrets; summarize them.

`scripts/score.sh <run> --workspace <ws>` scores a run (counts JSON database
pairs as well as markdown ones) and `scripts/checkpoint.sh` saves and restores
blueprints and test configs. State lives in `proxymock/tuning/LOOP.md`; template
and script details: [references/loop-file.md](references/loop-file.md).

## Fast path: one fix

If the first run is already close (accuracy within about 10 points of the
target, or one endpoint or field explains every failure), skip `LOOP.md` and the
checkpoints: run once, diagnose, change **one** thing, run again, confirm
accuracy and the match rate held, and report before and after in three lines.
Fall back to the full loop only if that one fix is not enough.

## Iteration 0: set up and baseline

1. **Decide where to run** (step 1 of `run-snapshot-replay`); note the evidence.
2. **Get a workspace.** Tuning edits files on disk, so it needs one even for
   cloud runs: `proxymock cloud pull snapshot <id>` or `report <id>`, or use a
   recording directory as is.
3. **Checkpoint:** `checkpoint.sh save <workspace> iter-0`.
4. **Baseline run.** Reuse an existing run made with the current blueprints;
   otherwise run once. Locally, run the app behind `proxymock mock` (with every
   `--map`) so the match rate is measured, and do the mocking check.
5. **Score:** `score.sh <run-dir | report-id> --workspace <workspace>`, and write
   the row to `LOOP.md`.
6. If accuracy meets the target, set `Status: done` and report. If the match
   rate is low, note it and hand it off first.

## Every later iteration

1. **Diagnose one problem.** Pick the biggest in the scoreboard and read the
   evidence in the order in
   [references/classification.md](references/classification.md), starting with
   the first failing response body. Write the hypothesis under **Next**.
2. **Classify it.** The table is in the same reference. **Mock problem:** set
   `Status: handed-off: improve-mock-match-rate`, run that skill, re-score when
   it returns; never edit mock blueprints here. **Generator problem**
   (credentials, a session-created ID, state, a volatile field): change one thing
   below. **SUT behaves differently:** a finding; stop tuning that endpoint.
   **Environment:** fix or report it; it does not count against the budget.
3. **Change exactly one thing.** `checkpoint.sh save <workspace> iter-<n>-before`,
   then prefer proxymock's own mechanisms:
   - `proxymock recommendations accept --in <ws> --id <id>` (generator transforms)
   - a transform in a blueprint (`proxymock transform` authors and tests it)
   - a **test-config assertion exclusion**, only for fields proven volatile:
     `{"type":"httpResponseBody","config":{"ignore":"generated_at,id"}}`. Create
     the config with `proxymock test-config new <name> --from standard` (older
     builds: `test-config compile | jq`), and prove volatility with `proxymock
     drift --source <run1> --source <run2>`. Steps, keys and the fallback:
     [references/test-config.md](references/test-config.md). The default
     `regression` config already ignores UUID and timestamp values, and
     `standard` asserts more, so first check what the default really fails on.
4. **Re-run and score** against the same target, with the workspace carrying the
   change. **Local:** blueprints and test configs in the workspace apply
   automatically; run the app behind the mock again, with `--test-config <name>`.
   **Cluster:** iterate locally (above) and confirm at the end with a cluster
   replay, as in Inputs.
   **Cloud:** push the workspace, not the old snapshot:
   `proxymock cloud replay --in <workspace> --name tune-<n> ...` with the same
   cluster, namespace, workload, mocks and `--test-config` as the baseline.
5. **Keep or revert.** Keep if accuracy improved and the match rate did not drop
   by more than noise (about 1 point, or 1 pair on small runs). Otherwise
   `checkpoint.sh restore <workspace> iter-<n>-before` and note why. Count the run.
6. **Continue or stop:** `done` (target met), `stalled` (two iterations without a
   kept improvement), `budget` (runs used = `--max-runs`), or `blocked` (needs a
   human: credentials, seeding data, re-recording, a production namespace, a
   real SUT regression).

## Hard rules

- One change per iteration. Two at once make the score meaningless.
- Never edit or delete recorded RRPairs to force a match.
- Never loosen the target, exclude a field without proof it varies on its own,
  or hide a real SUT difference to raise the score.
- Never mask or rewrite authentication material without asking.
- Never cancel a replay you did not start, or touch a production-looking
  namespace without asking.

## Result

Restore the best checkpoint first (full loop). Then end with exactly this block:

```
### Result
- **Ran:** what ran, against what
- **Outcome:** pass, fail, or the headline number
- **Numbers:** the 2 to 4 metrics that matter for this skill
- **Artifacts:** paths the run wrote
- **Next:** one suggested next step, naming the skill or giving a prompt
```

For this skill: **Ran** is where it ran and how many runs. **Outcome** is
accuracy before and after, and the loop status. **Numbers** are accuracy,
measured match rate, runs used, and real SUT findings (endpoint, field, recorded
vs replayed). **Artifacts** are `proxymock/tuning/LOOP.md` (full loop), the best
run directory and the files changed (blueprints, test configs). **Next** is
usually `proxymock-regression-test` to turn the tuned replay into a gate,
`improve-mock-match-rate` if mocks still miss, or re-recording for uncovered
paths. Put findings the tuning must not hide in the reply above the block.

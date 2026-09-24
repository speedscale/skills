---
name: tune-snapshot-replay
description: Iteratively tune a Speedscale snapshot or proxymock recording until its replay is trustworthy, in a persistent loop that re-runs the replay, locally or in the cloud, measures, changes one thing, and keeps or reverts. Owns the generator side (replayed responses that differ from the recording - expired credentials, IDs created during the session, stateful environments, legitimately volatile fields) and the loop itself, and hands mock-side fixes to improve-mock-match-rate. Use when the user asks to "tune this snapshot", "get this replay to pass", "raise replay accuracy", "the replay keeps failing, fix it", or wants a Ralph Wiggum style loop on a replay. For mock match rate alone, without re-running, use improve-mock-match-rate.
argument-hint: <snapshot-id | report-id | recording-dir> [--local | --cloud] [--target-accuracy 95] [--target-match 95] [--max-runs N]
---

# Tune a snapshot replay

Make a replay trustworthy: replayed responses match what was recorded
(**accuracy**, the generator side), and the app's outbound calls are answered
by mocks (**match rate**, the responder side). Work as a loop that survives a
lost context: the same instructions every iteration, all progress on disk.

Each iteration changes **one** thing, re-runs, and keeps the change only if
the score improved without hurting the other side. The loop ends when both
targets are met, progress stalls, the budget is spent, or a human has to
decide something.

The rule that matters most: **a real application failure is a finding, not
noise.** If the service under test (SUT) now returns a different answer
because of a code change, report it. Never mask, ignore or transform it away
to raise the score.

## Inputs

| Input | Meaning |
| --- | --- |
| Snapshot ID, report ID, or recording directory | what to tune; a report ID also gives you a first run to start from |
| `--local` / `--cloud` | where to run; default is where it was recorded (see below) |
| `--target-accuracy` | default 95 (% of replayed pairs matching) |
| `--target-match` | default 95 (% of outbound calls answered by mocks), and passthrough 0 unless the user wants some dependencies real |
| `--max-runs` | re-run budget; default 5 in the cloud, 10 locally |

Re-running is part of this skill. Confirm the budget once at the start when
it runs in the cloud (every cloud run pushes a snapshot, creates a report and
uses cluster capacity), then proceed without asking per run. Ask before any
namespace that looks like production.

## Prerequisites

- `proxymock` (and `speedctl` for the cloud) on PATH and signed in; `jq`.
  Missing? Use the [`install-speedscale`](../install-speedscale/SKILL.md)
  skill (CLI and auth only).
- The [`run-snapshot-replay`](../run-snapshot-replay/SKILL.md) skill: this
  skill uses its target detection and its run and monitor steps. Read it.
- Never print API keys. Never paste recorded bodies holding tokens, passwords
  or personal data; summarize them.

Scripts (in this skill's `scripts/`):

- `score.sh <run>`: one JSON scoreboard for a local replay directory or a
  pulled report ID. Uses `proxymock replay score` when available.
- `checkpoint.sh save|restore|list <workspace> <label>`: snapshot and restore
  `proxymock/blueprints` and `proxymock/testconfigs`, the only state tuning
  changes.

## The loop file

All state lives in `proxymock/tuning/LOOP.md` in the workspace. **Read it
first on every iteration.** If it does not exist, this is iteration 0: create
it.

```markdown
# Tuning loop: <snapshot or recording>

- Where: local | cloud (<cluster>/<namespace>/<workload>), because <evidence>
- Targets: accuracy >= 95, match >= 95, passthrough 0
- Budget: 5 runs (used: 0)
- Best: iteration 0 (checkpoint iter-0), accuracy 77.8, match 61.0
- Status: running | done | stalled | blocked: <reason>

| Iter | Run | Accuracy | Match | Pass-through | Change | Kept? |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | proxymock/results/replayed-... | 77.8 | 61.0 | 4 | baseline | - |

## Findings for the user
- (real SUT regressions, missing recordings, decisions needed)

## Next
- (the hypothesis for the next iteration)
```

If your agent has a loop runner (for example the Claude Code Ralph Wiggum
plugin, which re-feeds the same prompt until a completion phrase appears),
run this skill under it and use `Status: done` as the completion condition.
Without one, just keep iterating in this session; the loop file makes it
safe to stop and resume.

## Iteration 0: set up and baseline

1. **Decide where to run.** Follow step 1 of `run-snapshot-replay` (target
   detection, with the same defaults and the same rules for when to ask).
   Record the choice and the evidence in `LOOP.md`.
2. **Get a workspace.** Tuning edits blueprints on disk, so it needs a local
   proxymock workspace even for cloud runs:
   - a cloud snapshot: `proxymock cloud pull snapshot <id>`
   - a report: `proxymock cloud pull report <id>` (brings its snapshot too)
   - a recording directory: use its workspace as-is
3. **Checkpoint:** `checkpoint.sh save <workspace> iter-0`.
4. **Baseline run.** Reuse a run that already exists (the report you were
   given, or the latest local `replayed-*` with a `mocked-*` next to it) if it
   used the current blueprints. Otherwise run once with `run-snapshot-replay`.
   Locally, run the app behind `proxymock mock` so the match rate can be
   measured, and do its "check that mocking actually took effect" step.
5. **Score:** `score.sh <run-dir | report-id> --workspace <workspace>`. Write
   the row to `LOOP.md`.
6. If the baseline already meets both targets, set `Status: done` and report.

## Every later iteration

### 1. Diagnose: pick the biggest problem

Look at the scoreboard and pick **one** problem, largest first. Work down the
evidence in this order and stop as soon as it explains the problem:

1. **The first failing response body.** Read the replayed response next to
   the recorded one for the top failing endpoint (local: the pair's
   `replayFile` and `sourceFile` from `replay-verdict.json`; cloud: the pair
   in `generator-pairs.jsonl` or `proxymock/report-<id>/`). State in one
   sentence what differs.
2. **Mock outcomes** for the calls that endpoint makes: `NO_MATCH` and
   `PASSTHROUGH` calls around the same time.
3. **Logs:** locally the app log and `proxymock mock` log; in the cloud
   `generator-log.jsonl`, `responder-log.jsonl` and the report's replay
   events with their suggested fixes (`proxymock cloud replay status <id>`,
   or `watch-replay.sh` from `run-snapshot-replay` on older proxymock).
4. **proxymock's own suggestions:** `proxymock recommendations list --in
   <workspace>` (generator-side transforms). Responder-side fixes come from
   the `improve-mock-match-rate` skill (below).

### 2. Classify it

| Side | Symptom | Likely cause | The one change to try |
| --- | --- | --- | --- |
| Responder | `NO_MATCH`, `PASSTHROUGH`, low match rate | a signature that no longer matches, a call never recorded, or (locally) the app bypassing the proxy | use [`improve-mock-match-rate`](../improve-mock-match-rate/SKILL.md) for the iteration's change. Its playbook covers volatile signature fields, missing recordings and auth material. For a local run where you need per-call HIT/MISS/PASSTHROUGH, measure with [`proxymock-replay-tuning`](../proxymock-replay-tuning/SKILL.md). For proxy bypass, see the mocking check in `run-snapshot-replay` |
| Generator | 401 or 403 where the recording had 2xx | expired or re-signed credential | `recommendations list --type transform` for JWT re-signing, or a credentials preflight; ask before changing auth |
| Generator | 404 or empty result for an ID the app should know | an ID created earlier in the session (order, user, cart) is replayed verbatim but the app issued a new one | a correlation transform that carries the new value forward (recommendations often propose it); otherwise author one |
| Generator | 409 or duplicate errors | the app keeps state between runs: the recorded create already exists | reset or seed the environment; or make the key unique per run with a transform |
| Generator | body differs only in timestamps, generated IDs or ordering | response field legitimately varies | first prove it: the same field varies between two recorded responses, or across two replays with no code change (`proxymock drift --source <run1> --source <run2>`). Then exclude it in the test config assertions |
| Generator | a field or status changed for no data reason | **the SUT behaves differently** | stop tuning this endpoint. It is a finding: endpoint, field, recorded vs replayed |
| Either | everything fails from one point on | a setup call failed (login, handshake, session): the rest cascade | fix the first failure only, then re-run |
| Environment | connection refused, timeouts, pods restarting, replay Error | the run itself broke | fix or report the environment; it is not a tuning problem, and does not count against the budget if nothing ran |

Write the hypothesis in `LOOP.md` under **Next** before changing anything.

### 3. Change exactly one thing

1. `checkpoint.sh save <workspace> iter-<n>-before`.
2. Make the change, preferring proxymock's own mechanisms:
   - responder side: one fix through `improve-mock-match-rate` (it accepts
     and, if the projection does not move, undoes `proxymock match-rate`
     recommendations). Take one fix per iteration, not its whole loop, so
     the re-run still tells you what that fix did.
   - `proxymock recommendations accept --in <ws> --id <id>` (generator transforms)
   - a transform in a blueprint (`proxymock transform` to author and test it)
   - a test config assertion exclusion (`proxymock/testconfigs/<name>.json`,
     checked with `proxymock test-config compile`) only for fields proven
     volatile
3. Where it can be checked offline, check it first: a responder fix reports
   its projected match rate immediately, so a fix that does not move the
   projection is undone before it costs a run.

### 4. Re-run and score

Run again with `run-snapshot-replay`, against the same target, with the
workspace carrying the change:

- **Local:** blueprints and test configs in the workspace apply
  automatically. Run the app behind `proxymock mock` again.
- **Cloud:** push the workspace, not the old snapshot, or the change does not
  travel: `proxymock cloud replay --in <workspace> --name tune-<n> ...` with
  the same cluster, namespace, workload, mocks and `--test-config` as the
  baseline. `--snapshot-id` would replay the old blueprints.

Then `score.sh` the new run and add the row.

### 5. Keep or revert

- **Keep** if the targeted number improved and the other side did not drop
  by more than noise (about 1 point, or 1 pair on small runs). Record the new
  best and its checkpoint label.
- **Revert** otherwise: `checkpoint.sh restore <workspace> iter-<n>-before`,
  and note why it did not work, so you do not try it again.
- Increment the runs used.

### 6. Decide whether to continue

Set `Status` and stop when:

- **done:** both targets met.
- **stalled:** two iterations in a row without a kept improvement.
- **budget:** runs used = `--max-runs`.
- **blocked:** the next step needs a human: credentials, seeding data,
  re-recording, a production namespace, or a real SUT regression to look at.

Otherwise pick the next problem and continue.

## Finish

Restore the best checkpoint if the last state is not the best. Then report:

1. **Where it ran** and why.
2. **Before and after:** accuracy, match rate, pass-through, goals.
3. **What changed and why**, one line per kept change, plus what was tried
   and reverted.
4. **Findings** that tuning must not hide: SUT regressions (endpoint, field,
   recorded vs replayed), traffic that was never recorded, environment
   problems.
5. **Next steps**, offered not done: re-record missing paths, push the tuned
   blueprints for teammates and CI (`proxymock cloud push snapshot`), turn
   the result into a gate with `proxymock-regression-test` or
   `proxymock cloud replay status --wait` in CI.

## Hard rules

- One change per iteration. Two changes at once make the score meaningless.
- Blueprint, transform and test-config changes only. Never edit or delete
  recorded RRPairs to force a match.
- Never loosen a goal threshold, and never exclude a field from assertions
  without proof that it varies on its own. Never raise the score by hiding a
  real SUT difference.
- Never mask or rewrite authentication material without asking.
- Always leave the workspace at the best-scoring checkpoint.
- Never cancel a replay you did not start. Never touch a production-looking
  namespace without asking.

## Related skills

- [`run-snapshot-replay`](../run-snapshot-replay/SKILL.md): target detection, running, monitoring.
- [`analyze-replay-report`](../analyze-replay-report/SKILL.md): deeper evidence reading for one report.
- [`improve-mock-match-rate`](../improve-mock-match-rate/SKILL.md): owns responder-side fixes; this skill calls it for one fix per iteration.
- [`proxymock-replay-tuning`](../proxymock-replay-tuning/SKILL.md): measures per-call mock outcomes for a local run.
- [`proxymock-regression-test`](../proxymock-regression-test/SKILL.md): turn the tuned replay into a baseline gate.

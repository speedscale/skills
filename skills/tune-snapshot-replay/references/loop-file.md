# The loop file

All tuning state lives in `proxymock/tuning/LOOP.md` in the workspace. Read it
first on every iteration. If it does not exist, this is iteration 0: create it
from this template.

```markdown
# Tuning loop: <snapshot or recording>

- Where: local | cloud (<cluster>/<namespace>/<workload>), because <evidence>
- Target: accuracy >= 95 (match rate is watched, not tuned here)
- Budget: 5 runs (used: 0)
- Best: iteration 0 (checkpoint iter-0), accuracy 77.8, match 61.0
- Status: running | done | stalled | blocked: <reason> | handed-off: improve-mock-match-rate

| Iter | Run | Accuracy | Match (measured) | Pass-through | Change | Kept? |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | proxymock/results/replayed-... | 77.8 | 61.0 | 4 | baseline | - |

## Findings for the user
- (real SUT regressions, missing recordings, decisions needed)

## Next
- (the hypothesis for the next iteration)
```

If your agent has a loop runner (for example the Claude Code Ralph Wiggum
plugin, which re-feeds the same prompt until a completion phrase appears), run
the skill under it and use `Status: done` as the completion condition. Without
one, keep iterating in the session; the loop file makes it safe to stop and
resume.

## Scripts

In this skill's `scripts/`:

- `score.sh <run> [--workspace <ws>] [--mock-run <dir>]`: one JSON scoreboard
  for a local replay directory or a pulled report ID. Uses `proxymock replay
  score` when available; otherwise it reads `replay-verdict.json` and counts HIT,
  MISS and PASSTHROUGH in the mock run, across markdown and JSON (database)
  pairs. For a local run it pairs the replay with the mock run that served it
  (the latest `mocked-*` under `proxymock/results/` started no later than the
  replay); pass `--mock-run` when the mock ran under another name, and treat a
  `GUESS` note as unverified.
- `checkpoint.sh save|restore|list <workspace> <label>`: snapshot and restore
  `proxymock/blueprints` and `proxymock/testconfigs`, the state tuning changes.

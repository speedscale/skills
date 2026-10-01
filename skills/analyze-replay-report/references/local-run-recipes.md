# Local run recipes

Read on demand from `SKILL.md`. `RUN` is the run directory.

List the failing pairs, new ones first (`NEW` and `seen-in-baseline` only
appear when the run had a baseline):

```bash
jq -r '(.baselineDir != null) as $b | .pairs[]
  | select(.match != "pass" or (.bodyMatch // "pass") == "fail")
  | [(if .newMismatch then "NEW" elif $b then "seen-in-baseline" else "fail" end),
     .method, .endpoint, .recordedStatus, .observedStatus, (.bodyMatch // ""), .replayFile] | @tsv' \
  "$RUN/replay-verdict.json" | sort | head -30
```

No `replay-verdict.json` (a recording, a mock run, or an older replay)? Build
the report instead:

```bash
proxymock report --in "$RUN" --format dir --out /tmp/report-$(basename "$RUN")
```

Start from `digest.md`, then `scores.json`, `reliability.json`, and
`fix-prompts/`.

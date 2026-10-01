---
name: proxymock-summarize-recording
description: Summarize what a proxymock recording contains, including hosts and services, inbound and outbound endpoints, methods, status-code distribution, and request volume, then append proxymock's findings and recommendations. Use when users ask to summarize recordings, describe captured traffic, or get an overview of an RRPair directory before mocking or replaying.
argument-hint: --in <dir> [--out <file>]
---

# proxymock Recording Summary

Read a recording and produce a one-page brief: which hosts/services it touches,
the inbound endpoints (requests into your app) and outbound endpoints (the
downstream calls your app makes), methods, status codes, and volume, plus the
`proxymock report` digest of findings and recommendations. Use it to understand
a recording before you mock, replay, or hand it to a teammate.

This workflow uses local files and the `proxymock` CLI. It does not require
Speedscale Cloud access.

## Inputs

- `--in`: the recording / RRPair directory to summarize
  (`proxymock/recorded-<name>`).
- `--out`: markdown summary path. With `--out`, nothing else is left behind; the
  scratch digest goes to a temporary directory that is removed. Without it, the
  script writes `proxymock-summary-<ts>/summary.md` in the current directory.
- `--no-report`: structure only, skip the report digest.

Run the bundled script by its path inside this skill's installed directory
(`<skill-dir>` is the folder holding this `SKILL.md`), from your project root:

```bash
<skill-dir>/scripts/proxymock-summarize-recording.sh --in proxymock/recorded-<name> --out recording-brief.md
```

## What the summary contains

1. **Header:** total RRPairs across HTTP and other protocols; IN vs OUT split; protocols; hosts and services with counts; HTTP status-code mix (2xx/4xx/5xx and exact codes).
2. **Inbound endpoints:** `METHOD /path` your app served, with id-like path
   segments collapsed to `{id}` and query values to `{v}` (`/orders/{id}?ts={v}`)
   so endpoints group cleanly.
3. **Outbound endpoints and operations:** the downstream `METHOD /path` calls
   (query values collapsed the same way) and non-HTTP commands, such as SQL
   statements, your app made, grouped by host. These are the dependencies that
   need mocking to run offline.
4. **Findings & recommendations:** the `proxymock report --format prompt`
   digest (performance / reliability / security findings with fix guidance),
   appended verbatim.


## How to read it

- The **outbound endpoints** section is the mock surface: every distinct
  downstream call there must be in the mock set for the app to run with no
  network. A database mapped to `localhost` shows up under `localhost` with the
  SQL statements, next to the inbound requests; the statement counts divided by
  the inbound count are the statements per request.
- The **inbound endpoints** section is the replay surface: those are the
  requests a replay or load test will drive at the app.
- A status mix with `4xx`/`5xx` present means the recording captured error
  paths. Keep them for negative testing, or prune them if you only want the
  happy path mocked.

## Related

- **record-traffic:** makes the recordings this skill summarizes, and calls it
  as its last step.
- **proxymock-compare-results:** once you know what a recording holds, compare
  two of them for regressions.
- **proxymock-load-test:** drive the inbound endpoints this summary lists.

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

For this skill: **Ran** is the recording directory summarized. **Outcome** is
the headline (RRPair count, host count, status mix). **Numbers** are the inbound
and outbound counts, the number of hosts, and the 4xx/5xx share. **Artifacts**
is the summary markdown path. **Next** is usually `tune-snapshot-replay`,
`improve-mock-match-rate` or `proxymock-regression-test`.

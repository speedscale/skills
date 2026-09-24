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

- `--in`: the recording / RRPair directory to summarize.
- `--out`: markdown summary path (default `<work-dir>/summary.md`).
- `--no-report`: structure only, skip the report digest.

Run the bundled script:

```bash
./skills/proxymock-summarize-recording/scripts/proxymock-summarize-recording.sh \
  --in ./proxymock/recording --out recording-brief.md
```

If this skill has been copied outside `mock-lab`, replace
`./skills/proxymock-summarize-recording` with the copied skill directory.

## What the summary contains

1. **Header:** total RRPairs across HTTP and other protocols; IN vs OUT split; protocols; hosts and services with counts; HTTP status-code mix (2xx/4xx/5xx and exact codes).
2. **Inbound endpoints:** `METHOD /path` your app served, with id-like path
   segments collapsed to `{id}` so endpoints group cleanly.
3. **Outbound endpoints and operations:** the downstream `METHOD /path` calls and non-HTTP commands your app made, grouped by host. These are the dependencies that need mocking to run offline.
4. **Findings & recommendations:** the `proxymock report --format prompt`
   digest (performance / reliability / security findings with fix guidance),
   appended verbatim.

The script also prints a one-line headline (RRPair count, host count, status
mix) and the summary path.

## How to read it

- The **outbound endpoints** section is the mock surface: every distinct
  downstream call there must be in the mock set for the app to run with no
  network.
- The **inbound endpoints** section is the replay surface: those are the
  requests a replay or load test will drive at the app.
- A status mix with `4xx`/`5xx` present means the recording captured error
  paths. Keep them for negative testing, or prune them if you only want the
  happy path mocked.

## Related

- **proxymock-compare-results:** once you know what a recording holds, compare
  two of them for regressions.
- **proxymock-load-test:** drive the inbound endpoints this summary lists.

## Proof

```bash
./skills/proxymock-summarize-recording/scripts/prove-proxymock-summarize-recording.sh
```

The proof summarizes the committed `lab/proxymock/recording`, checks hosts, endpoints, status mix, and non-HTTP pair counts, and uses a local report stub to verify digest inclusion without cloud credentials.

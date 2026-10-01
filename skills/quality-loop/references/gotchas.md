# Quality loop reference

Read on demand from `SKILL.md`: gotchas that apply on more than one route, and
the optional dispatcher and `doctor`. Blueprint rules live in
[`proxymock-regression-test`](../../proxymock-regression-test/references/blueprints-and-caveats.md).
Terms (HIT, MISS, match rate, accuracy, verdict) are defined in
[`SKILL.md`](../SKILL.md#terms-used-the-same-way-in-every-skill).

## The native commands

Each intent is one CLI invocation and its exit code is the CI contract. The
dispatcher script (`scripts/quality-loop.sh`) only builds and prints these lines.

| Intent | Native command | Exits |
| --- | --- | --- |
| Did my change break anything? | `proxymock replay --in <rec> --test-against <url> --baseline <prior> --fail-on-new-mismatch` | 0 pass / 3 new mismatch |
| Is the incident fixed? | `proxymock replay --in <incident> --test-against <url> --verify-fix [--expect <re>]` | 0 fixed / 2 still reproduces / 3 collateral |
| Does the dependency match its spec? | `proxymock validate --spec <spec> --in <rrpairs>` | 0 conformant / 2 violations / 3 no spec route |
| What does a lying downstream do to my app? | `proxymock mock --in <rec> --fault '<pat>:<actions>' [-- <app cmd>]` | runs until stopped |
| What can this service sustain? | `proxymock replay --in <rec> --test-against <url> --vus N --for D --load-test` | 0 / 1 on `--fail-if` |

## Gotchas

- **Gate on the verdict, never on transport metrics.** `requests.failed` stays
  0 for a status regression: a 201 that becomes a 200 still completes the HTTP
  exchange. The per-pair verdict is the datum.
- **Body scoring is native and default.** Pairs carry `bodyMatch` and
  `bodyChanges[]` of `{severity, kind, endpoint, location, baseline,
  candidate}`. `--ignore-body-changes` restores status-only scoring. Newer
  proxymock flags a JSON type change (number to string) as `type_changed`; on
  older builds only a body-asserting test config catches it.
- **Baseline masking compares change sets.** A pair that failed in the baseline
  is exempt from *that same failure* only; a different failure on the same pair
  is a new mismatch (exit 3).
- **Volatile-value suppression follows value patterns, not field names.** The
  built-in scoring ignores values shaped like UUIDs and timestamps wherever they
  appear, so a UUID or ISO-8601 field passes without any config. Anything else
  that varies (a counter, a short id) is scored, and a raw `bodyMismatches: 0`
  says little: gate against a `--baseline`.
- **Recorded-error-reproduced is a match PASS.** Match compares observed
  against recorded, so faithfully replaying a captured 500 passes. This is why
  verify-fix inverts: an all-match run means the bug still reproduces.
- **Incident captures lack the fixed path's downstream traffic**, because the
  buggy handler usually errored before calling its dependency. Union the
  incident capture with a healthy recording (repeated `--in`) when mocking the
  fixed build's downstream.
- **`proxymock mock` needs an explicit `--in`.** It does not discover a
  recording from cwd. Repeated `--in` unions mock sources. Pass the recording
  directory, not the workspace root, or replay outputs get ingested as mock
  data.
- **A database needs the same `--map` on every command that starts the app**
  (`record`, `mock`). Without it the database is not mocked, and `mock` refuses
  to start while the real database is up because it binds the recorded backend
  port.
- **Fault patterns are matched against the bare path and host+path only**: no
  scheme, port, or method, so a plausible full-URL pattern matches nothing.
  When proxymock WRAPS an app the no-match warning goes to `proxymock.log`.
- **`--fault` is startup-only.** Only mock DATA hot-reloads
  (`--mock-reload-interval`). Restarting a mock that WRAPS the app restarts the
  app, so run recovery scenarios un-wrapped.
- **`connection=drop` returns a truncated 200**, which a status-only assertion
  scores as a pass. `refuse` and `reset` are indistinguishable from inside the
  app; `stall` needs a client-side timeout or it hangs.
- **`--response-selection random` is weighted by copy count and noisy.** When
  the failure ratio IS the measurement, use `rate=F/N` or round-robin.
- **`validate` treats undocumented response fields as violations**, with no
  flag to downgrade them.
- **A malformed RRPair is skipped silently.** The warning only appears at
  `-v -v`, so a bad edit shows up as a missing endpoint, not a loud failure.
- **Readiness probes belong on the app's own port.** Everything sent to the
  inbound port (4143) during `record` is recorded, so a `curl
  localhost:4143/healthz` loop adds pairs the app never served for real.
  Probe `localhost:<app port>` or rely on `--app-health-endpoint`.
- **Ctrl-C on `record` or `mock` with `--app-health-endpoint`** exits 1 and
  prints the usage on older builds. The recording is intact; treat it as a
  clean stop.
- **MCP parity.** `mock_server_start` exposes `fault`, `mock-timing`,
  `mock-reload-interval` and `response-selection`. Still absent: `proxy-out-port`,
  `health-port`, `app-health-endpoint`. `edit_rrpair` is body-only.

## The dispatcher (optional)

Run it by its path inside this skill's installed directory (`<skill-dir>` is
the folder holding this skill's `SKILL.md`), from your project root:

```bash
<skill-dir>/scripts/quality-loop.sh doctor
<skill-dir>/scripts/quality-loop.sh regression \
  --in ./proxymock/recorded-<name> --test-against http://localhost:8080 \
  --baseline ./proxymock/results/base
```

Every mode prints the command it is about to run to stderr, then execs it, so
the output and exit code are proxymock's own. Extra flags are forwarded
verbatim; `PROXYMOCK=/path/to/proxymock` overrides the binary. Modes:
`regression`, `verify-fix`, `contract`, `chaos`, `load`, and routes to
`compare`, `summarize` and `load-test`.

`doctor [--root DIR]` reports proxymock presence and version, recording
directories with pair counts (results of earlier runs under `proxymock/results/`
are not recordings and are skipped), blueprint staging, Node proxy support
(`fetch` ignores proxy env vars before 22.21/24; set `NODE_USE_ENV_PROXY=1` and
`NODE_EXTRA_CA_CERTS`), and whether ports 8080 and 4140 are free. A dev build
that prints `Client Version: undefined` skips the version check. Exit `0`
healthy, `1` with a `MISSING:` list, `2` on usage errors; warnings never fail
it.

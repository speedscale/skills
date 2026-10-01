---
name: proxymock-chaos-mock
description: >-
  Inject faults into a proxymock mock with native --fault flags so the downstream lies to your service on demand: 503s, 429s with Retry-After, corrupt or truncated bodies, per-endpoint latency, socket-level connection faults, and exact deterministic failure ratios via rate=F/N. Use when users ask to chaos-test a service against its dependencies, simulate a slow or failing downstream, test retry/backoff/timeout handling, or check what their app does when a dependency misbehaves.
argument-hint: "--in <recording-dir> --fault '<regexp>:<action>=<value>' [-- <app command>]"
---

# proxymock Chaos Mock

Turn a recording into a lying downstream. One native command:

```bash
proxymock mock --in ./proxymock/recorded-<name> \
  --fault '/v1/projects:status=503' \
  -- <your app command>
```

The faults are process flags, not data. The recording is served as-is: no copy, no RRPair edits, no variant to validate, nothing to roll back. What you observe is your service's resilience behavior, which is the point.

**Requires proxymock v2.5.814 or newer.** Connection faults in particular differ on older builds.

## Works with your stack (no bash required)

`proxymock mock` is an HTTP proxy in front of your dependencies. Your app talks to it over `--proxy-out-port` (default 4140) and nothing else in your stack changes, so the driver hitting your app can be k6, bruno, postman-cli, curl, your own integration suite, or a human clicking around.

```bash
# standalone: start the lying downstream, start your app separately against it
proxymock mock --in ./proxymock/recorded-<name> --proxy-out-port 4140 \
  --fault '/v1/projects:status=429,header=Retry-After:30'

# or let proxymock wrap the app so the proxy env is wired for you
proxymock mock --in ./proxymock/recorded-<name> \
  --fault '/v1/projects:connection=drop' -- go run .
```

`mock` runs until you stop it; there is no pass/fail exit code to gate on. The gate is whatever you assert about your app *while* it serves, so pair it with `proxymock replay` (proxymock-regression-test) or your own test driver. The bundled `quality-loop.sh chaos` is optional convenience that builds this exact line; the native command is the contract.

An app with a database needs the same `--map` the recording used. `proxymock mock` **requires an explicit `--in`**. It does not discover a recording from cwd. Repeated `--in` unions several recordings into one mock source set.

## Fault syntax

```text
--fault '<RE2 pattern>:<action>=<value>[,<action>=<value>...]'
```

Repeatable. The pattern is **unanchored** and is matched against the **bare path** and **host+path** only. Scheme, port and method are **not** in the candidate string, so `'https://api.example.com:443/v1/projects'` parses fine, starts fine, and matches nothing. Use a plain path substring like `'/v1/projects'`.

Actions:

| Action | Value | Notes |
| --- | --- | --- |
| `status` | `NNN` | body left intact |
| `header` | `Name:Value` | `Name=Value` is rejected |
| `latency` | Go duration | **unit required**: `2500ms`, `1.5s`; bare `2500` is rejected |
| `rate` | `F/N` | deterministic and periodic; composes with any other action |
| `body` | `corrupt` or `truncate[:bytes]` | corrupt = invalid JSON, truncate = well-formed but short |
| `connection` | `refuse`, `reset`, `stall`, or `drop` | socket-level, see below |

`rate=F/N` alone injects intermittent 503s. Only the `F/N` form is accepted: `0.5` and `50%` are rejected at startup.

Responses carrying a `status=`, `header=`, `body=` or `latency=` fault are tagged `x-speedscale-chaos: proxymock fault`; unfaulted responses carry `x-speedscale-chaos: none`, so match on the value, not on presence. Connection faults have no complete response to tag.

**A pattern that matches nothing warns where you are not looking.** proxymock prints `Warning: --fault pattern "..." matches no mock data, so it will never fire`, but when it **wraps your app**, its own output goes to `proxymock.log`, not your terminal. Standalone mocks print it. Read the log before believing an injected fault ran.

## Behavior worth knowing (details in the reference)

- **Connection faults**: `refuse` and `reset` are indistinguishable from inside
  the app. `stall` only fails if the client has a timeout. `drop` returns a
  200 with a silently short body, so **assert on body length or content**, not
  status.
- **Faults are startup-only.** Changing them restarts the mock, and a mock that
  wraps the app restarts the app too: run recovery scenarios unwrapped.
- **Use `rate=F/N` when the failure ratio is the measurement.** Never
  `--response-selection random`.
- **`body=` only does `corrupt` and `truncate`**; realistic payloads need an
  RRPair edit (MCP `edit_rrpair`, body-only).
- **MCP** exposes `fault`, `mock-timing`, `mock-reload-interval` and
  `response-selection`, but not `proxy-out-port`, `health-port` or
  `app-health-endpoint`.

Measurements and how each connection fault reaches the client:
[references/fault-reference.md](references/fault-reference.md).

## Interpretation

What the app under test does with each lie is the finding:

- **`status=503`**: an app that returns 200 from a dependent endpoint while the downstream 503s is swallowing errors, for example by ignoring the downstream status whenever the body still parses.
- **`status=429,header=Retry-After:30`**: check whether `Retry-After` survives to the app's own response. An app that strips it means its clients never see the hint, and one that retries a 429 immediately is worse.
- **`body=corrupt`**: an endpoint that passes garbage through as 200 is proxying decode failures to its own clients; the resilient behavior is a 5xx.
- **`latency=<d>`**: watch the app's timeout budget. Under it, slow 200s; over it, whatever the app does instead is the finding.
- **`connection=drop`**: the defect class no file edit could ever surface: 200 with a truncated body and no error anywhere in the chain. Gate on body length or content; status alone reports success.

## Related

- **proxymock-regression-test**: replay at the app while this faulted mock serves, to turn observed resilience behavior into a gate.
- **proxymock-perf-container**: drive load while the downstream is slow or flaky.
- **proxymock-verify-fix**: after fixing a resilience bug this exposed, prove the fix by replay.

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

For this skill: **Ran** is the fault set and the driver used against the app.
**Outcome** is what the app did with each lie (handled, swallowed, hung).
**Numbers** are client-visible failure ratio against the injected ratio,
timeouts, and responses with truncated or corrupt bodies. **Artifacts** are the
mock log and the driver output. **Next** is a fix for the weakest behavior
(then `proxymock-verify-fix`), or `proxymock-regression-test` to gate it.

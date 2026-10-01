# Chaos mock: fault behavior reference

Read on demand from `SKILL.md`.

## What each connection fault looks like

All four fire over **HTTP/2** as well as HTTP/1.1, and stay scoped to the endpoints the pattern matches: measured against the committed h2 recording, `/v1/projects` failed under every action while an untargeted `/v1/categories` kept its exact full 200 body. What differs is how the failure reaches you, which decides what a test can assert:

- **`refuse` and `reset` are the same finding.** Both cut the connection before a complete response arrives, and a Go HTTP client reports both as `unexpected EOF`. At the socket level they differ (`curl` exits 52 vs 56), but nothing above the transport can tell which one was injected. Do not write an assertion that claims to tell them apart.
- **`stall` only fails if the client has a timeout.** The mock accepts the request and never answers; without a client deadline the call hangs forever. Measured with `curl -m 8`: exit 28 at 8s. An app with no timeout hangs with it, which is itself the finding.
- **`drop` is the sharp one.** It truncates mid-stream, so the status line and headers are already on the wire: the response advertises a `Content-Length` it never delivers. The truncated length varies between runs, so assert that the body is short rather than a specific number. A pass-through handler returns **HTTP 200 with a silently short body**, which a status-only assertion scores as a pass. **Assert on body length or content.** A handler that JSON-decodes the body surfaces the truncation as a 5xx instead.

## Faults are startup-only

`--fault` is read **once at startup**. Only mock DATA hot-reloads, via `--mock-reload-interval 1s`, which picks up an RRPair edit in about a second. Changing the fault set means restarting the mock.

That has a consequence for recovery scenarios: **restarting a mock that wraps the app restarts the app too**, destroying whatever in-process state the recovery was supposed to test. Run recovery scenarios with the mock **unwrapped** and the app started separately against `--proxy-out-port`.

## Ratio discipline

When the client-visible failure ratio is the measurement, use `rate=F/N`. It is exact and periodic: `rate=1/3` measured `503 200 200 503 200 200` over six probes, so retry policies are testable exactly rather than statistically. With `1/2` and one immediate retry every client call should succeed; a client-visible failure rate equal to F/N means no retries at all.

`--response-selection random` exists but is **weighted by copy count and noisy** (a 50% expectation measured 15/40), which is useless as an analytical instrument. Stay on the default `round-robin`, or use `rate=F/N`.

## What still needs file edits

Native faults replaced the whole variant-building engine, with one exception: `body=` only does `corrupt` and `truncate`. Scenario-accurate payloads (a real rate-limit envelope, a schema-drifted object) still need an RRPair edit, either by hand or with the MCP `edit_rrpair` tool, which is **body-only** (`file`, `side`, `body`).

## MCP parity

`mock_server_start` exposes `fault`, `mock-timing`, `mock-reload-interval` and `response-selection` alongside `in-directory`, `out-directory` and `log-to`, so faults themselves no longer need the CLI. Still absent over MCP: **`proxy-out-port`, `health-port`, `app-health-endpoint`**. An MCP-only agent can inject faults but cannot pin the proxy-out port or wait on a readiness endpoint; shell out to the CLI for that.

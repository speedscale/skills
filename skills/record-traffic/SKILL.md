---
name: record-traffic
description: Record a service's real traffic with proxymock into RRPair files, locally, so it can be replayed, mocked, regression-tested and load-tested. Finds how the app starts and what it depends on (HTTP APIs, Postgres, MySQL and other databases), wraps it with proxymock record, drives traffic, stops once inbound requests and every outbound host and database are captured, then summarizes it. Use when the user asks to "record traffic", "capture a recording", "record my service", or when a regression, replay or mock task has no recording yet. Kubernetes capture is not covered yet.
argument-hint: "[<name>] [-- <app run command>]"
---

# Record traffic

Capture what a service receives and what it calls, as RRPair files under
`proxymock/recorded-<name>/`. One good recording feeds every later step: replay,
mocks, the regression gate and the load test. This skill runs the app on this
machine. See [In a Kubernetes cluster](#in-a-kubernetes-cluster) for the other
place.

## Prerequisites

- `proxymock` on PATH. If it is missing, use the
  [`install-speedscale`](../install-speedscale/SKILL.md) skill (CLI only).
- The app runs on this machine, and its dependencies (a database, sibling
  services) are reachable from it.
- Never print secrets. Recordings hold real headers and bodies: do not paste
  them back, and do not commit a recording that holds credentials or personal
  data without saying so.

## 1. Find how the app starts and what it depends on

Read the repo before recording. You need three answers:

1. **The run command** and the port it listens on (`Makefile`, `package.json`
   scripts, `docker-compose.yaml`, a README, `go run .`). Ask the user only if
   the repo does not say.
2. **Outbound HTTP(S) hosts**: base URLs in config or environment variables.
   These need no changes. proxymock sets `http_proxy` and `https_proxy` for the
   command it wraps, and most clients honor them.
3. **Databases** and other non-HTTP dependencies (Postgres, MySQL and so on).
   These do not follow proxy variables. Each needs a `--map` and the app
   pointed at the mapped port:

   ```text
   --map <listen-port>=<protocol>://<real-host>:<real-port>
   e.g. --map 15432=postgres://localhost:5432
   ```

   Then set the app's connection setting (`DATABASE_URL`, a `--db-port` flag)
   to `<listen-port>` instead of the real port. Use a listen port that is not
   the real one. If the repo has a compose file, the real port is in it.

Write the dependency list down; step 4 checks the recording against it.

## 2. Start the app under proxymock

Pick the name from the app or the scenario, for example `recorded-orders`.

```bash
DATABASE_URL=postgres://user:pass@localhost:15432/db?sslmode=disable \
proxymock record --out proxymock/recorded-<name> \
  --map 15432=postgres://localhost:5432 \
  --app-port <port> --app-health-endpoint /healthz \
  -- <run command>
```

Keep the app's own port as `--app-port` (default 8080). proxymock then listens
on **4143** in front of it: send traffic to `http://localhost:4143`, not to the
app's port, or the inbound side is not recorded. Outbound calls are recorded
through port 4140. Leave `--out` off to get a timestamped directory.

MCP equivalent: `record_traffic_start` (with `out-directory` and `app-port`) and
`record_traffic_stop`. The MCP tool has no `map` option, so an app with a
database needs the CLI.

`--app-health-endpoint` (a path or full URL) makes proxymock wait for the app
before you drive traffic. On older builds Ctrl-C with it set prints the usage and
exits 1; the recording is intact, so treat it as a clean stop.

Run it in the background and read its log until the app is ready. If the app
exits or the log shows a proxy or port error, fix that first. Do not drive
traffic at a half-started app.

Language notes:

- **Java, HTTPS calls fail with `PKIX path building failed`**: the JVM does not
  trust proxymock's CA. Run `proxymock admin certs --jks` and start the app with
  `~/.speedscale/certs/cacerts.jks` as its truststore
  (`-Djavax.net.ssl.trustStore=...`, plus `trustStorePassword` if the output names
  one). Newer proxymock sets this for a wrapped JVM.
- **Node**: built-in `fetch` ignores proxy variables on old versions. Use Node
  22.21 or newer. Newer proxymock sets `NODE_USE_ENV_PROXY` and
  `NODE_EXTRA_CA_CERTS`; on older ones export both yourself
  (`NODE_USE_ENV_PROXY=1`, `NODE_EXTRA_CA_CERTS=$HOME/.speedscale/certs/tls.crt`).
  A client with its own networking (`undici` agent, `axios` with `proxy: false`)
  must honor the proxy variables in code.
- **Python, Go, Ruby, .NET**: usually nothing extra. If outbound calls are not
  captured, the client is ignoring `https_proxy`.

## 3. Drive traffic

Use what the repo already has, aimed at `http://localhost:4143`:

- a traffic driver or load script (look for `cmd/traffic`, `scripts/`, `k6`,
  `Makefile` targets such as `make smoke`)
- the integration or end-to-end tests, if they take a base URL
- otherwise ask the user to exercise the app (curl, a browser, their client)
  through port 4143 and tell you when they are done

Cover every endpoint that matters at least once, including one error path.
Repeating a request adds little; missing an endpoint costs a re-record.

## 4. Stop when the recording is complete

Check the recording directory before stopping, not after:

```bash
ls proxymock/recorded-<name>              # one directory per host, plus localhost
find proxymock/recorded-<name> -type f | sed 's#.*/##' | sed 's/.*\.//' | sort | uniq -c
```

- `localhost/` holds the inbound requests (`.md`, host `localhost:<app port>`).
  It must have pairs for the endpoints you drove.
- Every **outbound host** from step 1 has its own directory.
- Every **database** from step 1 shows up as pairs too, in `localhost-<port>/`
  when the mapped backend runs on this machine (for example `localhost-5432/`).
  Postgres and MySQL RRPairs are `.json` even though HTTP is `.md`. Older
  proxymock builds put them in `localhost/` next to the inbound requests; if you
  see `.json` files there, they are database calls, so filter inbound pairs by
  direction (`direction: IN`) rather than by directory.

Stop when all three hold. If a dependency is missing, the app is not using the
proxy or the mapped port. Fix the wiring and record again from the start,
because a partial recording gives a mock with holes. Stop the app with Ctrl-C
(or `record_traffic_stop`), then confirm the process is gone (`list_running`,
or the port is free).

## 5. Summarize it

Run
[`proxymock-summarize-recording`](../proxymock-summarize-recording/SKILL.md) on
the new directory and put its headline numbers in the result. Then offer the
next step: replay and tune the tests
([`tune-snapshot-replay`](../tune-snapshot-replay/SKILL.md)), tune the mocks
([`improve-mock-match-rate`](../improve-mock-match-rate/SKILL.md)), or a
regression gate ([`proxymock-regression-test`](../proxymock-regression-test/SKILL.md)).

## In a Kubernetes cluster

Not covered yet. Use the `cluster` MCP tool directly: `action=inject` turns eBPF
capture on for one workload without restarting it, `capture-status` shows it, and
`action=uninject` turns it off; then pull the traffic into the workspace. Ask
before touching a production-looking namespace.

## Rules

- One recording per scenario. Do not merge an unrelated run into it.
- Never edit RRPair files to make a recording look complete. Record again.
- Do not leave the app or proxymock running after the recording.

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

For this skill: **Ran** is the app command and the traffic source. **Outcome**
is `complete` or what is missing. **Numbers** are inbound pairs, outbound hosts
and databases captured against those expected, and error-status pairs.
**Artifacts** is the recording directory. **Next** is usually
`tune-snapshot-replay` or `proxymock-regression-test`.

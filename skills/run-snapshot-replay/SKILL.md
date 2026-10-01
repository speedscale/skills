---
name: run-snapshot-replay
description: Run a Speedscale snapshot or proxymock recording as a replay where it was recorded (a cluster workload through Speedscale cloud, or the app on this machine) and follow it to a result, including a check that local mocking took effect. Use when the user asks to "run this snapshot", "replay snapshot <id>", "replay it in the cluster", "kick off a replay", "watch the replay", or "is my replay done yet". For a local regression gate against a known target, use proxymock-regression-test. Hands off to analyze-replay-report, tune-snapshot-replay or improve-mock-match-rate.
argument-hint: <snapshot-id | recording-dir> [--local | --cloud] [--workload <name>] [--test-config <id>]
---

# Run a snapshot replay and monitor it

Start one replay, watch it to a terminal status, and report the result with
evidence. Two places a replay can run:

| Mode | What runs where | Needs |
| --- | --- | --- |
| **Local** | `proxymock mock` answers the app's dependencies, `proxymock replay` sends the recorded requests to the app on this machine | proxymock and a way to start the app; no account, no cluster |
| **Cloud** | Speedscale cloud tells the registered cluster's operator to run the generator (and responder) against a workload | a Speedscale login and a cluster whose inspector is registered with the tenant |

Input: a cloud snapshot ID or a local recording directory
(`proxymock/recorded-<name>`, `proxymock/snapshot-<id>/`). Optional: `local` or
`cloud`, a workload or address, a test config. Ask only for what you cannot work
out. Local mode needs `proxymock` and `jq` only; cloud also needs `speedctl`
signed in to the tenant (missing tools: [`install-speedscale`](../install-speedscale/SKILL.md),
CLI and auth only). Never print the API key or paste recorded bodies holding secrets.

## 1. Decide where to run (default: where it was recorded)

Both detectors are read-only. Prefer the built-in one; it also prints the exact
replay command, with the last run's test config and mocks.

```bash
S=<this skill's directory>/scripts
if proxymock cloud replay defaults --help 2>/dev/null | grep -q 'proxymock cloud replay defaults'; then
  proxymock cloud replay defaults --snapshot-id <id> -o json   # or: --report-id <id>, --in <recording-dir>
else
  $S/detect-replay-target.sh --snapshot-id <id>             # or: --in <recording-dir>
fi
```

It prints JSON with `origin` (`cluster`, `local`, `unknown`), `cluster`,
`namespace`, `workload`, `workloads`, `clusterRegistered`, `localAddress`,
`priorReport` and `evidence` (fields and evidence order:
[references/target-detection.md](references/target-detection.md)). Choose the mode:

| User said | Detector says | Mode |
| --- | --- | --- |
| `local` / "on my machine" / "with proxymock" | anything | Local |
| `cloud` / "in the cluster" / names a cluster | anything | Cloud |
| nothing | `origin: cluster`, `clusterRegistered: true` | Cloud, same cluster, namespace and workload |
| nothing | `origin: cluster`, `clusterRegistered: false` | Ask: offer local mode, another registered cluster (`speedctl infra inspectors`), or the kubeconfig route |
| nothing | `origin: local` | Local, against `localAddress` |
| nothing | `origin: unknown` | Ask |

`workload` is `null` when earlier replays routed to several: ask which. Say the
choice and evidence in one line, then proceed unless a row says ask.

## 2. Cloud mode

Steps and commands are in [references/cloud-mode.md](references/cloud-mode.md):
pre-flight (workload ready, `proxymock cloud replay ... --dry-run`, reuse the
prior test config, keep mocking every recorded dependency, ask before any
production-looking namespace), start (capture the report ID), then
`proxymock cloud replay status <report-id> --wait --timeout 60m`. Give the user
the report link right away, relay each new event as one line, and never cancel on
your own. `--in <dir>` pushes a local recording as a new snapshot with its tuning
blueprints; `--snapshot-id` does not.

## 3. Local mode

No account or cluster. Every run goes under `proxymock/results/`, which is
where proxymock writes by default and where `replay score`, `doctor` and the
tuning loop look.

### Get the traffic

A cloud snapshot ID: `proxymock cloud pull snapshot <id>` lands it in
`proxymock/snapshot-<id>/`. A recording from
[`record-traffic`](../record-traffic/SKILL.md) is already
`proxymock/recorded-<name>/`.

### Start the app behind the mock server

Ask how the app starts unless the repo says (`Makefile`, `package.json`, `go run .`).
Then, in one terminal:

```bash
proxymock mock --in proxymock/recorded-<name> \
  --out proxymock/results/mocked-$(date +%Y-%m-%d_%H-%M-%S) \
  --map 15432=postgres://localhost:5432 \
  --app-health-endpoint /healthz -- <app start command>
```

- **Reuse every `--map` the recording used**, and point the app at the mapped
  ports as in `record-traffic`. Without the map the database is not mocked, and
  `mock` refuses to start while the real database is up, because it binds the
  recorded backend port.
- Pass the recording directory to `--in`, not the workspace: the workspace also
  holds earlier runs under `results/`.
- If the app already runs with `http_proxy`/`https_proxy` set to `localhost:4140`,
  start `proxymock mock` without `--`. The MCP `mock_server_start` has no `map`
  option, so an app with a database needs the CLI.
- If the app cannot run locally, say so and offer cloud mode.

### Replay

In another terminal, against `localAddress` (details, baselines and gates:
[`proxymock-regression-test`](../proxymock-regression-test/SKILL.md)):

```bash
proxymock replay --in proxymock/recorded-<name> --test-against <localAddress> \
  --out proxymock/results/replayed-$(date +%Y-%m-%d_%H-%M-%S) [--test-config <name>]
```

Then stop the mock server (Ctrl-C, or `mock_server_stop`).

### Check that mocking took effect

Never report a local run as mocked without this check. It is the one command
that shows whether the replay hit real services:

```bash
proxymock replay score proxymock/results/replayed-<ts> \
  [--mock-run proxymock/results/mocked-<ts>] -o json \
  | jq '{accuracy: .accuracy.rate, match: .matchRate | {rate, matched, noMatch, passthrough, topMissingHosts}}'
```

Newer proxymock pairs the mock run itself for runs under `proxymock/results/`;
older builds say "not inside a proxymock workspace", and `--mock-run` is the
fallback. Read `match.rate` (measured; terms in
[`quality-loop`](../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill)):
100 with zero passthrough means fully mocked. A `passthrough` count above zero
means those calls reached real services, even though the replay passed. `noMatch`
above zero means the mock had the host but no matching request
(`improve-mock-match-rate`). No calls at all means the app bypassed the proxy.
The interpretation table and the fallback for when `topMissingHosts` is empty:
[references/local-mocking-check.md](references/local-mocking-check.md). If you
cannot tell, say mocking is unverified.

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

For this skill: **Ran** is where it ran and why (the detector's evidence).
**Outcome** is the verdict (`Passed`, `Missed Goals`, `Error`, or the local
verdict). **Numbers** are accuracy or pair counts, goals missed, measured match
rate with passthrough count, and whether mocking was verified. **Artifacts** are
the report link or the `proxymock/results/` run directories. **Next** is
`analyze-replay-report` if it failed, `tune-snapshot-replay` for accuracy, or
`improve-mock-match-rate` for mock misses. List every warning or error event
above the block. Offer the next step, do not do it.

## Rules

- One replay per request. Do not re-run on failure; report and offer.
- Never cancel a replay you did not start; ask before cancelling one you did.
- Never change the workload, its namespace, or the test config to make a run pass.
- Replays run against real services. Ask before any production-looking
  namespace, and never run with `--no-mocks` there.

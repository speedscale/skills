---
name: run-snapshot-replay
description: Run a Speedscale snapshot or a local proxymock recording as a replay and follow it to a result, either on this machine with proxymock or in a Kubernetes cluster through Speedscale cloud. Defaults to replaying against the same place the traffic was recorded (the cloud workload it was captured from, or the local app address). Use when the user asks to "run this snapshot", "replay snapshot <id>", "kick off a replay", "rerun the test", "watch the replay", or "is my replay done yet". Reports the verdict and hands off to analyze-replay-report or tune-snapshot-replay.
argument-hint: <snapshot-id | recording-dir> [--local | --cloud] [--workload <name>] [--test-config <id>]
---

# Run a snapshot replay and monitor it

Start one replay, watch it until it reaches a terminal status, and report the
result with evidence. Two places a replay can run:

| Mode | What runs where | Needs |
| --- | --- | --- |
| **Local** | `proxymock mock` answers the app's dependencies, `proxymock replay` sends the recorded requests to the app on this machine | proxymock, a way to start the app; no account, no cluster |
| **Cloud** | Speedscale cloud tells the registered cluster's operator to run the generator (and responder, when mocking) against a workload | a Speedscale login and a cluster whose inspector is registered with the tenant |

A third route exists for a cluster the user reaches through their kubeconfig
but that is not registered with Speedscale cloud: `proxymock cluster replay
start`. Use it only when the user asks for it or cloud is unavailable.

## Inputs

| Input | Looks like |
| --- | --- |
| Cloud snapshot ID | a UUID; `speedctl get snapshot <id>` returns it |
| Local recording | a directory of RRPair files, e.g. `proxymock/recorded-2026-09-23_10-00-00Z`, or a pulled `proxymock/snapshot-<id>/` |

Optional, from the prompt: `local` or `cloud`, a workload or address to
target, a test config, whether to mock dependencies. Ask only for what you
cannot work out below.

## Prerequisites

- `proxymock` on PATH; for cloud mode also `speedctl`, both signed in to the
  tenant that owns the snapshot. `jq`.
- If either is missing or unauthenticated, use the
  [`install-speedscale`](https://raw.githubusercontent.com/speedscale/skills/main/skills/install-speedscale/SKILL.md)
  skill first (CLI and auth only; never touch a cluster for this).
- Never print the API key. Never paste recorded bodies containing tokens,
  passwords, or personal data back to the user.

## 1. Decide where to run (default: where it was recorded)

Newer proxymock has this built in, using the same logic as the dashboard's
replay wizard. Use it when present, and the bundled detector otherwise. Both
are read-only. Check for the subcommand by its usage line: `proxymock cloud
replay` accepts flags that make a bare `--help` succeed either way.

```bash
S=<this skill's directory>/scripts
if proxymock cloud replay defaults --help 2>/dev/null | grep -q 'proxymock cloud replay defaults'; then
  proxymock cloud replay defaults --snapshot-id <id> -o json   # or: --report-id <id>, --in <recording-dir>
else
  $S/detect-replay-target.sh --snapshot-id <id>             # or: --in <recording-dir>
fi
```

The built-in command also prints the exact command to replay it there,
including the test config and mock attachment the last run used. Prefer that
command when it is present.

It prints JSON: `origin` (`cluster`, `local`, or `unknown`), `cluster`,
`namespace`, `workload`, `workloads`, `clusterRegistered`, `localAddress`,
`priorReport` (the last replay of this snapshot, with its `testConfig` and
`replayMode`), and `evidence`, one sentence saying why. The evidence order is
the one the dashboard's replay wizard uses to pre-fill its target:

1. The newest earlier replay of this snapshot (report tags `k8sClusterName`,
   `ns`, `workload`).
2. The snapshot's metadata: `meta.namespaces[].inspector.clusterName` and
   `name`, plus `meta.serviceName`.
3. The recorded inbound RRPairs' tags: `k8sClusterName`,
   `k8sAppPodNamespace`, `k8sAppLabel` mean cluster capture. No cluster tags
   means a local proxymock recording; the target address is the busiest
   inbound slice from `proxymock cluster replay prepare`.

Choose the mode:

| User said | Detector says | Mode |
| --- | --- | --- |
| `local` / "on my machine" / "with proxymock" | anything | Local |
| `cloud` / "in the cluster" / names a cluster | anything | Cloud |
| nothing | `origin: cluster`, `clusterRegistered: true` | Cloud, same cluster, namespace and workload |
| nothing | `origin: cluster`, `clusterRegistered: false` | Ask: the recording cluster is not registered with this tenant. Offer local mode, another registered cluster (`speedctl infra inspectors`), or the kubeconfig route |
| nothing | `origin: local` | Local, against `localAddress` |
| nothing | `origin: unknown` | Ask |

`workload` is `null` when earlier replays routed to several workloads; list
`workloads` and ask which one, or reuse all of them as `--route`s.
`k8sAppLabel` is the pod's `app` label, usually but not always the
Deployment's name: confirm it exists before starting (step 2).

Say the choice and the evidence in one line before starting, for example:
"Replaying in the cloud against banking-replay/banking-user on dev-decoy,
where report 924b1c0c last replayed this snapshot." Then proceed; do not wait
for a confirmation unless a row above says ask.

## 2. Cloud mode

### Pre-flight (read-only)

```bash
speedctl infra workloads -n <namespace> --cluster <cluster> \
  | jq -r '.workloads[] | [.name, .type, "\(.nReady)/\(.nTotal) ready"] | @tsv'
proxymock cloud replay --cluster <cluster> -n <namespace> --workload <workload> \
  --snapshot-id <id> [--test-config <config>] --dry-run
```

The dry run prints the resolved cluster, namespace, routes, mocks, and test
config without pushing or starting anything. Check:

- The workload exists and is ready. If not, stop and show the list.
- Test config: reuse `priorReport.testConfig` when there is one; otherwise the
  built-in `regression`.
- Mocks: the CLI mocks every recorded outbound dependency by default, which
  makes the replay repeatable. If `priorReport.replayMode` is
  `generator-only`, the last run hit real dependencies; keep that with
  `--no-mocks` and say so.
- The namespace looks like production (`prod`, `production`, `live`): ask
  before starting. A replay sends real requests to the workload.

A local recording directory (no snapshot ID) is pushed as a new snapshot by
the same command: pass `--in <dir>` instead of `--snapshot-id`. That push
carries the workspace's tuning blueprints; `--snapshot-id` does not.

### Start

```bash
proxymock cloud replay --cluster <cluster> -n <namespace> --workload <workload> \
  --snapshot-id <id> [--test-config <config>] -o json
```

Capture the report ID from the output. MCP equivalent: `cloud_replay` with
`action=start`. Always state the mock choice explicitly (`mock_enabled: true`,
`mocks`, or `mock_enabled: false`) rather than relying on a default: older
proxymock versions default the MCP tool to mocking nothing.

### Monitor

Newer proxymock has a status command; use it when present, and the bundled
watcher otherwise:

```bash
if proxymock cloud replay status --help 2>/dev/null | grep -q 'proxymock cloud replay status'; then
  proxymock cloud replay status <report-id> --wait --timeout 60m
else
  $S/watch-replay.sh <report-id> --interval 30 --timeout 60m
fi
```

Both print each status change and each new replay event (warning or error,
with the operator's suggested resolutions), then a summary. Exit codes:

| Code | `cloud replay status` | `watch-replay.sh` |
| --- | --- | --- |
| 0 | Passed | Passed |
| 1 | Missed Goals | Missed Goals |
| 2 | usage error | Error or Canceled |
| 4 | Error or Canceled | - |
| 5 | report could not be read | - |
| 124 | still running at timeout | still running at timeout | Run it in the
background if your agent can, and tell the user the report link right away:
`https://<app host>/report/<report-id>` (the host from `speedctl` config,
usually `app.speedscale.com`).

Status flow: `Initializing` (operator provisioning generator, responder, SUT
patch) → `Testing` (traffic flowing) → `Analyzing` → `Passed`, `Missed Goals`,
`Error`, or `Canceled`.

While it runs:

- Relay each new event to the user as it appears, one line each. An `ERROR`
  event usually decides the outcome; do not wait for the end to mention it.
- If the user's kubeconfig reaches the cluster, `proxymock cluster replay
  status <report-id> -n <namespace>` shows the stage breakdown, and
  `proxymock cluster replay logs <report-id> --source generator` tails live
  generator, responder and SUT logs.
- Stuck in `Initializing` for more than 10 minutes: read
  `speedctl infra events -n <namespace> --cluster <cluster>` and report what
  it says (image pull, admission webhook, readiness timeout). Do not cancel on
  your own; offer `speedctl infra cancel-replay` or `cloud_replay
  action=cancel`.

## 3. Local mode

### Get the traffic

A cloud snapshot ID: pull it into the workspace first.

```bash
proxymock cloud pull snapshot <id>        # lands in ./proxymock/snapshot-<id>/
$S/detect-replay-target.sh --in proxymock/snapshot-<id>   # now finds localAddress
```

### Start the app behind the mock server

Ask the user how they start the app unless it is obvious from the repo (a
`Makefile` target, `package.json` start script, `go run .`). Then:

```bash
proxymock mock --in <recording-dir> --out proxymock/mocked-$(date +%Y-%m-%d_%H-%M-%S) \
  --app-health-endpoint <health path or url> -- <app start command>
```

This answers the app's outbound calls from the recording and records what it
served, so the mock match rate can be read afterwards. If the app is already
running with `http_proxy`/`https_proxy` pointed at `localhost:4140`, start
`proxymock mock` without `--`. MCP equivalent: `mock_server_start`.

If the app cannot run locally (it needs the cluster's network or data), say
so and offer cloud mode instead.

### Replay and monitor

```bash
OUT=proxymock/replayed-$(date +%Y-%m-%d_%H-%M-%S)
proxymock replay --in <recording-dir> --test-against <localAddress> --out "$OUT" \
  [--test-config <config>] --log-to "$OUT.log"
```

A local replay is synchronous. For a long one run it in the background and
report progress from the number of RRPair files in `$OUT` against the
inbound count from `replay prepare`; the log has the running totals. MCP
equivalent: `replay_traffic`, then `list_running` and `read_process_logs`.

When it exits, stop the mock server (Ctrl-C, or `mock_server_stop`) and read:

```bash
jq '{verdict, summary, goals}' "$OUT/replay-verdict.json"
proxymock match-rate analyze --in proxymock      # mock match rate of this run
```

Exit code 1 means a goal or `--fail-if` condition failed; the verdict file says
which.

### Check that mocking actually took effect

Local mocking depends on the app sending its outbound calls through
`proxymock mock`, which does not always happen. Never report a local run as
mocked without checking. Compare the recording's outbound pairs with what the
mock server saw (the `mocked-*` directory):

| What you see | What it means | Tell the user |
| --- | --- | --- |
| The recording has outbound pairs, the mock saw none | The app did not use the proxy: proxy env vars not honoured, a client that ignores them, or a database driver needing `--map` | "Mocking did not take effect: the app reached its real dependencies." Name the likely cause for the app's language or client |
| Some calls `PASSTHROUGH` | Those went to the real service: the host is not in the recording, or the protocol is not mocked | List the hosts, and say the results for them came from real services |
| Calls `NO_MATCH` / `MISS` | The mock had the host but no matching request; the app got an error from the mock | List the top signatures; tuning (`tune-snapshot-replay`) is the fix |
| No `mocked-*` run at all | The mock server never started or wrote nothing | Say mocking status is unknown, and why |

If you cannot tell (no recording of outbound traffic to compare against, or
the app was started outside your control), say that mocking is unverified
rather than guessing.

## 4. Report

Reply with:

1. **Where it ran** and why (the detector's evidence), with the report link or
   the local output directory.
2. **Verdict**: status, success rate or pair counts, each goal with expected
   and actual.
3. **What happened on the way**: every warning or error event, in order.
4. **Next step**, offered not done:
   - Failed or low match rate: analyze it with
     [`analyze-replay-report`](../analyze-replay-report/SKILL.md).
   - The user wants it higher: iterate with
     [`tune-snapshot-replay`](../tune-snapshot-replay/SKILL.md).

## Rules

- One replay per request. Do not re-run on failure; report and offer.
- Never cancel a replay you did not start, and ask before cancelling one you did.
- Never change the workload, its namespace, or the test config to make a run
  pass.
- Replays run against real services. Ask before any production-looking
  namespace, and never run with `--no-mocks` there.

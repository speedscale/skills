# Cloud mode: pre-flight, start, monitor

Read on demand from `SKILL.md` step 2. `$S` is this skill's `scripts/` directory.
Cloud runs use the terms in [`quality-loop`](../../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill):
a cloud report's `MATCH` is a HIT and its `NO_MATCH` is a MISS.

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
| 124 | still running at timeout | still running at timeout |

Run it in the background if your agent can, and tell the user the report link right away:
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

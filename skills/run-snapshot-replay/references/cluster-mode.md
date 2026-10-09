# Cluster mode: replay a workload through the kubeconfig

Read on demand from `SKILL.md`. proxymock analyzes the recording on this
machine, stages the snapshot in the cluster's forwarder over a port-forward,
and has the operator run the replay there. The snapshot and the report never
reach Speedscale cloud, so the replay needs no login and leaves no dashboard
link.

Needs: the Speedscale operator in the cluster
([`install-speedscale`](../../install-speedscale/SKILL.md)) and the kube context
the user named. Say the context (`kubectl config current-context`) before
starting, never act on another one, and ask before a production-looking
namespace: the operator restarts the workload to put it under test and reverts
it afterwards.

## Pre-flight (read-only)

```bash
proxymock cluster workloads -n <namespace>
proxymock cluster replay prepare --in proxymock/recorded-<name>
```

`prepare` lists the inbound slices the replay can send and the outbound
dependencies it can mock. Every recorded dependency is mocked by default; keep
that unless the user asks otherwise.

## Pick the mode

| Mode | Test config | What decides the verdict |
| --- | --- | --- |
| **regression** | the config the user tuned in `tune-snapshot-replay`, else a copy of the built-in `regression` with value types checked (below) | its goals, usually `passAssertPct >= 100`: every response matches the recording |
| **load** | a workspace copy of a built-in performance config, sized for the cluster | its latency and throughput goals |

The built-in `regression` config compares each response's status, content
type and field paths, not its values, so the fields that change on every run
need no tuning. It also misses a field whose type changes, such as a number
that becomes a string. For a regression gate, copy it and add the type check
to its `httpResponseSchema` assertion:

```bash
proxymock test-config new <name> --from regression
# in proxymock/testconfigs/<name>.json, on the httpResponseSchema assertion:
#   "config": {"matchType": "true"}
proxymock test-config compile <name>
```

Run the baseline replay with it once on known-good code: it should pass. A
field that legitimately changes type between runs goes in that assertion's
`ignore` list.

For load, copy a performance config and size it. The built-ins assume a large
cluster (100 virtual users for 5 minutes); a laptop cluster wants about 10 for
a minute:

```bash
proxymock test-config new <name> --from performance_100replicas
# edit proxymock/testconfigs/<name>.json: generator.stages[0].virtualUsers.virtualUsers and .duration
proxymock test-config show <name>
```

Performance configs run in low data mode: responses are not compared, and the
verdict comes from the goals alone. To fail on dropped requests, add a goal on
`responseRate`.

**Comparing two builds** (a slow change, `APP_SLOW=1` against `0`): the
goals cover every request together, so an endpoint that is a small share of
the traffic barely moves them. Read the per-endpoint latency the result lists
instead, and compare the same endpoint across the runs. Keep the runs
comparable:

- Use a light load (2 virtual users for 30 seconds). Heavy load measures
  contention, which can hide a per-request cost such as an N+1 query.
- A replay against a real database writes to it, and each run adds rows the
  next one reads. Reset the tables the recorded writes touch before each run.
- Run both builds with the same config, mocks and data.

A workspace test config and the workspace's tuning blueprints are staged with
the replay, so what was tuned on this machine applies in the cluster.

## Start and follow it

```bash
proxymock cluster replay start --in proxymock/recorded-<name> \
  -n <namespace> --workload <workload> --snapshot-source local \
  [--test-config <name>] --wait
```

`--wait` prints each stage as it happens, then the result: the verdict,
success rate, every goal with its expected and actual value, the
notifications behind a miss, and each endpoint's request count and latency. It exits nonzero when the replay missed its goals
or did not complete, so the same command is a CI gate.

MCP: the `cluster` tool with `action=replay-start` (`snapshot_source` `local`),
then `action=replay-status` with `replay_name` until the Results stage is done;
its output ends with the same result.

To read a finished replay again:

```bash
proxymock cluster replay status -n <namespace> <replay-name>
```

The replay is garbage-collected a while after it finishes; the result is only
readable while it exists, so put it in your report when it ends.
`analyze-replay-report` reads cloud reports and local runs, not this one: work
from the goals and notifications above.

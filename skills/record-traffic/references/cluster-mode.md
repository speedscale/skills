# Record a workload in a Kubernetes cluster

Read on demand from `SKILL.md`. The steps mirror local mode: find the
dependencies, turn capture on, drive traffic, stop when the recording is
complete, pull it into the workspace, turn capture off.

## Before you start

- The Speedscale operator runs in the cluster. If it does not, use
  [`install-speedscale`](../../install-speedscale/SKILL.md) first.
- Use the kube context the user named. Check it with
  `kubectl config current-context` and say it before changing anything; never
  switch to or act on a context the user did not choose. Ask before touching a
  production-looking namespace (`prod`, `production`, `live`).
- `proxymock cluster status` says whether the data plane is installed,
  reachable, and allowed to work. Fix what it reports before going on.
- Captured traffic reaches the workspace through Speedscale cloud, so this
  mode needs a Speedscale login (`proxymock cloud search --help` works).

## 1. Find the workload and what it calls

```bash
proxymock cluster workloads -n <namespace>
proxymock cluster dependencies -n <namespace> --workload <workload>
```

Write down the outbound hosts and databases; step 4 checks the recording
against them. The repo's manifests or Helm values name the rest.

## 2. Turn capture on

```bash
proxymock cluster capture inject -n <namespace> --workload <workload>
proxymock cluster capture status -n <namespace> --workload <workload>
```

MCP equivalent: the `cluster` tool with `action=inject` and
`action=capture-status`.

- **eBPF capture (the default)** attaches to the running pods without a
  restart. Connections the app opened before capture attached (a database
  pool) are picked up mid-stream; that is enough for replay and mocks.
- **JVM workloads**: add `--java-agent`. It restarts the workload, and the
  agent captures what eBPF cannot see inside the JVM's TLS.
- **Go workloads**: eBPF reads HTTPS through the binary's symbols. A binary
  built with `-ldflags="-s -w"` is stripped, and its HTTPS calls are not
  captured. Rebuild without those flags if outbound hosts are missing.

## 3. Drive traffic

Note the time in UTC first; the pull uses it.

```bash
date -u +%Y-%m-%dT%H:%M:%SZ
```

Use what the repo has: an in-cluster traffic Job, the end-to-end tests aimed
at the workload's Service, or `kubectl port-forward svc/<service> 8080:<port>`
and a local driver. Cover every endpoint that matters at least once, including
one error path.

## 4. Stop when the recording is complete

Captured pairs reach Speedscale cloud about a minute after the traffic. Count
them by direction and protocol until the numbers stop growing:

```bash
proxymock cloud search <service> --from <start-utc> --limit 0
```

Stop when the inbound requests, every outbound host and every database from
step 1 are there. If one is missing, check `capture status` and the notes in
step 2, fix it, and drive traffic again.

## 5. Pull it into the workspace

MCP: `pull_remote_recording` with `service`, `start-time` set to the time from
step 3, `filter-query` `(cluster IS "<cluster name>")`, and `out-directory`
`proxymock/recorded-<name>`. The cluster name is the `clusterName` the
operator was installed with:

```bash
kubectl -n speedscale get configmap speedscale-operator -o jsonpath='{.data.CLUSTER_NAME}'
```

Without the MCP server, make a snapshot and pull it:

```bash
speedctl create snapshot --name <name> --service <service> --start <start-utc> \
  --filter '(cluster IS "<cluster name>")'
proxymock cloud pull snapshot <snapshot-id>
```

The pull lands in `proxymock/snapshot-<id>/`; every proxymock tool reads it as
a recording.

## 6. Turn capture off

```bash
proxymock cluster capture uninject -n <namespace> --workload <workload>
```

MCP: `cluster` with `action=uninject`. Removing the Java agent restarts the
workload again. Recorded traffic is untouched.

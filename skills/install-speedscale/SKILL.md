---
name: install-speedscale
description: End-to-end install of Speedscale driven by an AI agent - the speedctl and proxymock CLIs on this machine and the Speedscale Operator Helm chart into a Kubernetes cluster - including installing missing prerequisites (Homebrew, kubectl, Helm), API-key setup without leaking the key, per-platform Helm values (EKS, GKE, AKS, minikube, kind, OpenShift), post-install verification, and wiring the proxymock MCP server into the user's coding agent. Use whenever the user wants to install, set up, onboard, upgrade, reinstall, repair, or uninstall Speedscale, speedctl, proxymock, or the Speedscale operator; asks how to get Speedscale running in a cluster or on a laptop; mentions the speedscale helm chart, operator-helm, or `helm install speedscale-operator`; or hits an install error such as a failed pre-install job, a webhook error, or `speedctl: command not found`. Trigger even if they name only one of the three components - the skill decides which ones apply.
compatibility: Needs a shell (sh/bash, or PowerShell + WSL on Windows), curl, and network access to downloads.speedscale.com, app.speedscale.com, and speedscale.github.io. Cluster steps need a kubeconfig with cluster-admin-ish rights.
---

# Install Speedscale

You are installing up to three things. Decide which ones apply before running
anything, because a laptop-only user never needs the operator and a platform
team wiring a shared cluster may not want proxymock on the bastion host.

| Component | What it is | Needed when |
| --- | --- | --- |
| `speedctl` | CLI for the Speedscale cloud: pull/push snapshots, run replays, manage clusters | Always useful; required for `speedctl check operator` verification |
| `proxymock` | Local record / mock / replay CLI with a built-in MCP server and web UI | Any developer laptop; anyone who wants AI-agent access to Speedscale |
| Speedscale Operator | Helm chart (`speedscale/speedscale-operator`) that captures traffic in Kubernetes and runs in-cluster replays | User has a cluster to record from or replay into |

Both CLIs are the same binary family, install to `~/.speedscale/`, and share
`~/.speedscale/config.json`. Authenticating one authenticates the other.

## Ground rules (read these, they explain the shape of everything below)

- **Do not run `speedctl install`.** It is an interactive TUI wizard that
  exits immediately without a TTY, and even with one it expects a human at the
  prompts. Drive Helm directly; you get the same result and can see every value.
- **Never print, echo, paste, or log an API key.** Keys live in
  `~/.speedscale/config.json` and in the `SPEEDSCALE_API_KEY` environment
  variable. Pass them by reference (`"$SPEEDSCALE_API_KEY"`, a Kubernetes
  Secret, `scripts/apikey.sh` inside a command substitution). If a command
  would put the key on the command line where it lands in shell history or
  your transcript, restructure it.
- **If a command opens a browser or waits on a prompt, stop and hand it
  to the user.** `speedctl init` / `proxymock init` without `--api-key` do
  this on purpose; `speedctl uninstall` prompts unless `--force`; `init`
  asks per detected IDE unless `-y`. Nothing in this skill should sit
  blocked on a TTY.
- **User-space installs first, `sudo` only with permission.** Every Speedscale
  binary installs under `$HOME` with no root. Prerequisites (Helm, kubectl)
  also install fine in user space. Ask before any `sudo`, and say why.
- **Idempotent by construction.** Every phase starts with a check and skips
  work that is already done. `helm upgrade --install` rather than `helm
  install`. Re-running this skill on a healthy machine should change nothing.
- **A cluster is not yours to surprise.** Before the Helm step, state the kube
  context you are about to modify and what will be created. If the context
  name or server URL smells like production (`prod`, `prd`, `live`), stop and
  confirm; a first Speedscale install belongs on dev/staging.
- **Keep a running install log.** Append each phase's outcome to a short list
  you print at the end (see Phase 7). The user may leave and come back.

## Phase 0: Discover

Run the bundled preflight. It only reads state and prints a report:

```bash
sh scripts/preflight.sh
```

(Every `scripts/...` path in this skill is relative to the skill's own
directory; run them by absolute path.)

Read the whole report, then decide the **mode**:

- **local** - no kubeconfig, no reachable cluster, or the user only mentioned
  proxymock/laptop work. Phases 1 (curl only), 2, 3, 6, 7.
- **cluster** - reachable cluster and the user wants capture/replay in it.
  All phases.
- **cli-only** - user explicitly wants speedctl for a cluster someone else
  installed. Phases 1-3, 5 (verification only), 7.

Resolve these before moving on; each later phase consumes them:

| Resolve | From | Default / rule |
| --- | --- | --- |
| `MODE` | user intent + preflight | local / cluster / cli-only |
| `KUBE_CONTEXT` | `kubectl config current-context` | ask if more than one plausible context |
| `PROVIDER` | preflight node labels / server URL | eks, gke, gke-autopilot, aks, minikube, kind, k3s, openshift, other |
| `CLUSTER_NAME` | context name, sanitized | `[a-z0-9-]`, <= 63 chars, recognizable to teammates |
| `TENANT` | `speedctl check` after Phase 3 | must match what the user expects |
| `EXISTING_RELEASE` | preflight `helm list -A` | if present: upgrade or verify, never a second install |
| `CHART_VERSION` | `helm search repo speedscale/speedscale-operator` | latest unless the user pins |
| `AGENT_CLIENTS` | preflight | which MCP configs Phase 6 will touch |

Tell the user the mode and which components you will install in one short
paragraph, then proceed. Only pause for an answer when something in the
report is genuinely ambiguous (two candidate contexts, an unsupported OS).

## Phase 1: Prerequisites

Fill gaps the preflight found. Prefer the package manager the machine already
uses; fall back to the vendor's official user-space install. Details and
per-OS commands are in `references/cli.md` under "Prerequisites".

| Need | macOS | Linux | Windows |
| --- | --- | --- | --- |
| `curl` + `openssl`/`shasum` | present | `apt-get`/`dnf` (needs sudo) | present in PowerShell; speedctl needs WSL |
| `kubectl` (cluster mode) | `brew install kubectl` | official binary to `~/.local/bin` | `winget install Kubernetes.kubectl` |
| `helm` 3 or 4 (cluster mode) | `brew install helm` | `get-helm-3` script with `HELM_INSTALL_DIR=$HOME/.local/bin` | `winget install Helm.Helm` |
| Homebrew (optional) | install only if the user wants it; scripts work without it | Linuxbrew is not worth adding just for this | n/a |

After each install, verify with a version command and make sure the directory
is on `PATH` for the *user's* shell, not just yours. Adding a line to
`~/.zshrc` or `~/.bashrc` is fine; tell the user you did it.

## Phase 2: Install the CLIs

Skip a CLI that the preflight shows as present and current: the preflight
prints the client version next to the cloud version (`speedctl version`), and
a client many builds behind the cloud is worth a `speedctl update` (or a
re-run of the proxymock install script). Two exceptions: a version string
with a `-g<hash>` suffix is a locally built binary, and a brew-managed copy
should be upgraded with `brew upgrade`. Overwriting either with the install
script is destructive; ask first.

**Homebrew machine** (brew present and the user already uses it):

```bash
brew install speedscale/tap/speedctl speedscale/tap/proxymock
```

**Everything else (macOS, Linux, WSL):** the official scripts download the
right arch, verify a SHA-256 checksum, and place the binary in
`~/.speedscale/` without root.

```bash
sh -c "$(curl -Lfs https://downloads.speedscale.com/speedctl/install)"
sh -c "$(curl -Lfs https://downloads.speedscale.com/proxymock/install-proxymock)"
```

Do not mix brew and script installs for the same binary: you end up with two
copies and `PATH` order decides which one runs. Pin a version by appending
`-s vX.Y.Z` to either script if the user needs to match a cluster.

Then make sure `~/.speedscale` is on `PATH` (the scripts do not do this) and
confirm:

```bash
speedctl version --client
proxymock version
```

Windows without WSL: proxymock ships a native `proxymock.exe`; speedctl does
not. See `references/cli.md` for the PowerShell steps.

## Phase 3: Authenticate

Both CLIs share one config, so initialize once. Choose the path by whether a
human is present:

1. **Human at the keyboard (default):** ask the user to run `proxymock init`
   (or `speedctl init`) in their own terminal. It opens a browser sign-in and
   writes the config. You cannot complete a browser flow for them.
2. **Key already available:** if `SPEEDSCALE_API_KEY` is set in the
   environment, or the user pastes a key *into their own terminal*, run
   `speedctl init --api-key "$SPEEDSCALE_API_KEY" -y`. Never ask the user to
   paste a key into the chat.
3. **Headless/CI:** same as 2. Note for the user that non-interactive init
   requires proxymock Pro or Speedscale Enterprise.

Where keys come from: <https://app.speedscale.com/profile> (enterprise
tenants) or <https://app.speedscale.com/proxymock/signup> (free proxymock).

Verify without exposing anything:

```bash
speedctl check
```

It should end with `All checks were successful` and print the tenant name and
server version. That tenant name is what the cluster will register under, so
repeat it back to the user; a wrong tenant here means a cluster in the wrong
account later.

`init` also offers to write the proxymock MCP server config into every
coding agent it detects. Say yes when it asks; Phase 6 covers the rest.

## Phase 4: Install the operator (cluster mode)

Full option matrix, platform notes, GitOps/Argo CD rendering, and upgrade
flow live in `references/operator.md`. The default path:

**4a. Reuse before install.** If the preflight found a `speedscale-operator`
release in any namespace, this is an upgrade or a repair, not an install:
skip to Phase 5 if it is healthy, or to the upgrade section at the bottom
if the user asked for a newer version. Two operators in one cluster fight
over the webhooks.

**4b. Pre-install checks.** Read-only, needs speedctl authenticated, and
only for a fresh install (it fails by design when the namespace already
exists; on an existing install run `speedctl check operator -n speedscale`
instead):

```bash
speedctl check operator --pre -n speedscale
```

Failures here are RBAC or API-version problems; fix them before Helm rather
than after a half-applied release. The needed create permissions are listed in
`references/troubleshooting.md`.

**4c. Pick a cluster name.** If a release already exists, keep its name
(`helm -n speedscale get values speedscale-operator -o json | jq -r .clusterName`);
renaming re-registers the cluster and orphans its history in the dashboard.
For a fresh install derive it from the kube context, lower-cased,
`[a-z0-9-]` only, no longer than 63 chars. It becomes the label users see in
the dashboard, so prefer something a teammate recognizes (`eks-dev-us-east-1`
over `arn-aws-eks-...`). Confirm it with the user in the same breath as the
context confirmation from the ground rules.

**4d. Put the API key in a Secret, not in Helm values.** The chart accepts a
Secret name, which keeps the key out of `helm get values`, release history,
and any rendered manifest you commit:

```bash
kubectl create namespace speedscale --dry-run=client -o yaml | kubectl apply -f -
kubectl -n speedscale create secret generic speedscale-apikey \
  --from-literal=SPEEDSCALE_API_KEY="$(sh scripts/apikey.sh)" \
  --from-literal=SPEEDSCALE_APP_URL="$(sh scripts/apikey.sh --app-url)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

`scripts/apikey.sh` reads the key for the current context from the config
(or `SPEEDSCALE_API_KEY`) and prints only that, so the command substitution
keeps it off your transcript. `--app-url` prints the context's Speedscale
host instead (`app.speedscale.com` for almost everyone; BYOC, on-prem, and
Speedscale's own dev tenants differ, and a cluster registered against the
wrong host silently lands in the wrong account). If the user insists on `--set apiKey=...`, use
`--set apiKey="$SPEEDSCALE_API_KEY"` and never a literal.

**4e. Write a values file.** Start from this and add the platform block from
`references/operator.md` that matches the preflight's provider guess:

```yaml
# speedscale-values.yaml
apiKeySecret: speedscale-apikey
clusterName: <cluster-name>
# same host as `scripts/apikey.sh --app-url`; omit only when it is app.speedscale.com
appUrl: <app-url>
# "" for prod clusters; the default "java" deploys a small demo app used by the tutorial
deployDemo: "java"
# eBPF capture (recommended). Leave enabled: true only if every node passes the
# preflight's arch/kernel check (x86_64 >= 5.15, arm64 >= 6.0). BTF is confirmed
# only when nettap starts; a crash-looping speedscale-nettap pod means set false.
ebpf:
  enabled: true
```

For an existing release, start from its live values minus the key instead
of this template, so nothing the previous installer chose is lost:

```bash
helm -n speedscale get values speedscale-operator -o json | jq 'del(.apiKey)' > speedscale-values.yaml
```

Save it somewhere durable in the user's repo or home dir (not a temp dir) and
tell them where; the same file is reused for every upgrade.

**4f. Install.**

```bash
helm repo add speedscale https://speedscale.github.io/operator-helm/
helm repo update speedscale
helm upgrade --install speedscale-operator speedscale/speedscale-operator \
  -n speedscale --create-namespace \
  -f speedscale-values.yaml \
  --wait --timeout 10m
```

Helm runs pre-install hook jobs that validate the key and connectivity
before any operator resources are applied. If it fails with
`failed pre-install: job failed: BackoffLimitExceeded`, read the job log
before retrying:

```bash
kubectl -n speedscale logs job/speedscale-operator-pre-install
```

Then `helm -n speedscale uninstall speedscale-operator`, delete the job, fix
the cause (almost always a wrong tenant/key or blocked egress), and re-run.
`references/troubleshooting.md` has the full list.

## Phase 5: Verify

Run the bundled checker (works for a cluster you installed or one that was
already there):

```bash
sh scripts/verify.sh speedscale
```

It checks the Helm release, the CRD, the operator/forwarder/inspector
rollouts, webhook configurations, the `speedscale-nettap` DaemonSet when eBPF is on, and
finishes with `speedctl check operator` if speedctl is available. Everything
green means the cluster has registered with the tenant. Two things to eyeball
after it passes:

- `speedctl infra inspectors` lists the new cluster by name. If it does not
  appear within a minute, the operator pod is up but registration is failing;
  look at its logs for `self-check` or certificate errors.
- The user can see it at <https://app.speedscale.com/> under Infrastructure.

The cluster part is done only when all of these are true:

- [ ] `helm -n speedscale status speedscale-operator` is `deployed`
- [ ] operator, forwarder, and inspector Deployments are Available
- [ ] `speedctl check operator -n speedscale` ends `All checks were successful`
- [ ] `speedctl infra inspectors` lists `CLUSTER_NAME`
- [ ] if eBPF is on: `speedscale-nettap` DaemonSet READY equals DESIRED
- [ ] the values file is saved at a path the user knows about

If the verifier fails, do not loop on reinstalls. Match the symptom in
`references/troubleshooting.md`; most failures are one of five known causes.

## Phase 6: Wire the coding agent (MCP + skills)

proxymock's MCP server gives the agent record/mock/replay locally plus a
`cluster` tool that talks to the operator you just installed (`status`,
`inject`, `replay-*`, logs, topology). Install it into every detected client:

```bash
proxymock mcp install --yes
```

(`--yes` skips the per-client confirmation; on proxymock builds older than
the one that added it, drop the flag and answer the prompts, or use
`proxymock init -y` which does the same thing. Either form needs Phase 3
done first: the command refuses to run without an initialized config.) For an IDE that is not
auto-detected, `proxymock mcp json` prints the config block to paste. When
proxymock runs somewhere the IDE cannot spawn it (remote dev box, container),
`proxymock mcp run --http` serves Streamable HTTP and `proxymock mcp install
--http` writes the matching client entry.

For Claude Code specifically, the installer also drops this skill and
`improve-mock-match-rate` under `~/.claude/skills/`, so the user can re-run
`/install-speedscale` later for upgrades. The agent's MCP client must be
restarted to pick up a new server; say so.

Once connected, a quick end-to-end proof is asking the agent (or calling the
tool yourself if you are that agent) for `cluster` with `action: status`; it
reports the operator and forwarder health through the same path the
dashboard uses.

## Phase 7: Report

Finish with this block, filled in. It is what the user forwards to a teammate.

```
Speedscale install - <date>
Mode: local | cluster | cli-only
Machine: <os/arch>, shell <name>
speedctl: <version> at <path>      proxymock: <version> at <path>
Tenant: <name>                     Config: ~/.speedscale/config.json
Cluster: <context> -> clusterName <name>, namespace speedscale, chart <version>
Values file: <path>                API key: Secret speedscale/speedscale-apikey
eBPF: enabled|disabled (<reason>)  Demo app: deployed|skipped
Verification: <pass|fail summary>  Dashboard: https://app.speedscale.com/
Agent wiring: <clients configured> (restart the client to load the MCP server)
Changed on this machine: <PATH edits, files written, packages installed>
Next: run the tutorial at https://docs.speedscale.com/tutorial/ | add capture targets | ...
```

## Upgrades, reinstalls, uninstall

- **Upgrade the operator:** `helm repo update speedscale` then the same
  `helm upgrade --install ... -f speedscale-values.yaml`. No values file on
  disk (someone installed with `--set`)? Rebuild one without exposing the
  key: `helm -n speedscale get values speedscale-operator -o json | jq
  'del(.apiKey)'`, then move the key into the Secret from 4d. Restart captured
  workloads afterwards (`kubectl -n <ns> rollout restart deployment`) so
  sidecars/agents pick up the new version. CRDs are not upgraded by Helm; see
  `references/operator.md` for the manual step on major versions.
- **Upgrade CLIs:** `speedctl update` (or `brew upgrade`). proxymock: re-run
  its install script.
- **Uninstall the operator:** `helm -n speedscale uninstall
  speedscale-operator`, then `kubectl delete crd trafficreplays.speedscale.com`.
  `speedctl uninstall --force` does a fuller sweep (webhooks, leftover
  certs) and is the right tool after a botched manual delete. Never delete the
  `speedscale` namespace by hand first: a dangling mutating webhook will then
  block every deployment in the cluster (fix in troubleshooting).
- **Uninstall CLIs:** `brew uninstall ...` or `rm ~/.speedscale/{speedctl,proxymock}`
  and remove the `PATH` line. `~/.speedscale/config.json` holds the key;
  remove it too if the machine is being handed off.

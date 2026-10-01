# Cluster and full install reference

Detail for the cluster path of the install-speedscale skill: discovery,
prerequisites, speedctl, the operator install, verification, upgrades and
uninstall. The laptop-only path is in SKILL.md and does not need any of this.
Every `scripts/...` path is relative to the skill's own directory; run the
scripts by absolute path.

## Contents

1. Discover (mode and values to resolve)
2. Prerequisites (kubectl, Helm)
3. Install speedctl and proxymock
4. Authenticate and check the tenant
5. Install the operator
6. Verify the cluster
7. Upgrades, reinstalls, uninstall

## 1. Discover

Run the bundled preflight. It only reads state and prints a report:

```bash
sh scripts/preflight.sh
```

(Every `scripts/...` path in this skill is relative to the skill's own
directory; run them by absolute path.)

Read the whole report, then decide the **mode**:

- **local** - no kubeconfig, no reachable cluster, or the user only mentioned
  proxymock/laptop work. The local path in SKILL.md; nothing here.
- **cluster** - reachable cluster and the user wants capture/replay in it.
  The local path, then sections 1-6 here.
- **cli-only** - user explicitly wants speedctl for a cluster someone else
  installed. Sections 1-4 and 6 (verification only).

Resolve these before moving on; each later section consumes them:

| Resolve | From | Default / rule |
| --- | --- | --- |
| `MODE` | user intent + preflight | local / cluster / cli-only |
| `KUBE_CONTEXT` | `kubectl config current-context` | ask if more than one plausible context |
| `PROVIDER` | preflight node labels / server URL | eks, gke, gke-autopilot, aks, minikube, kind, k3s, openshift, other |
| `CLUSTER_NAME` | context name, sanitized | `[a-z0-9-]`, <= 63 chars, recognizable to teammates |
| `TENANT` | `speedctl check` after section 4 | must match what the user expects |
| `EXISTING_RELEASE` | preflight `helm list -A` | if present: upgrade or verify, never a second install |
| `CHART_VERSION` | `helm search repo speedscale/speedscale-operator` | latest unless the user pins |
| `AGENT_CLIENTS` | preflight | which MCP configs the local path in SKILL.md will touch |

Tell the user the mode and which components you will install in one short
paragraph, then proceed. Only pause for an answer when something in the
report is genuinely ambiguous (two candidate contexts, an unsupported OS).

## 2. Prerequisites

Fill gaps the preflight found. Prefer the package manager the machine already
uses; fall back to the vendor's official user-space install. Details and
per-OS commands are in `references/cli.md` under "Prerequisites".

| Need | macOS | Linux | Windows |
| --- | --- | --- | --- |
| `curl` + `openssl`/`shasum` | present | `apt-get`/`dnf` (needs sudo) | present in PowerShell; speedctl needs WSL |
| `kubectl` (cluster mode) | `brew install kubectl` | official binary to `~/.local/bin` | `winget install Kubernetes.kubectl` |
| `helm` 3 or 4 (cluster mode) | `brew install helm` | `get-helm-3` script with `HELM_INSTALL_DIR=$HOME/.local/bin` | `winget install Helm.Helm` |
| Homebrew (optional) | install only if the user wants it; scripts work without it | Linuxbrew is not worth adding just for this | n/a |

**Windows:** the supported path is WSL2. Run this whole skill, the CLIs, and
the app under test inside WSL2 and follow the Linux column. Native Windows is
not verified; `references/cli.md` has the PowerShell steps for proxymock only,
at the user's own risk.

After each install, verify with a version command and make sure the directory
is on `PATH` for the *user's* shell, not just yours. Adding a line to
`~/.zshrc` or `~/.bashrc` is fine; tell the user you did it.

## 3. Install speedctl and proxymock

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

Windows: use WSL2 (see section 2). A native `proxymock.exe` exists but is not
verified for this flow; `references/cli.md` has its PowerShell steps.

## 4. Authenticate and check the tenant

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
coding agent it detects. Say yes when it asks; SKILL.md covers the MCP and skills step.

## 5. Install the operator

Full option matrix, platform notes, GitOps/Argo CD rendering, and upgrade
flow live in `references/operator.md`. The default path:

**4a. Reuse before install.** If the preflight found a `speedscale-operator`
release in any namespace, this is an upgrade or a repair, not an install:
skip to section 6 if it is healthy, or to section 7
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

## 6. Verify the cluster

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

## 7. Upgrades, reinstalls, uninstall

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

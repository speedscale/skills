---
name: install-speedscale
description: "Install Speedscale with an AI agent - proxymock on this machine (record, mock, replay, MCP server, skills), and optionally the speedctl CLI and the Speedscale Operator Helm chart in a Kubernetes cluster (EKS, GKE, AKS, minikube, kind, OpenShift). Covers API-key setup without leaking the key, wiring the proxymock MCP server and the full Speedscale skill set into the user's coding agent, a local proof that it works, and cluster verification. Use whenever the user wants to install, set up, onboard, upgrade, reinstall, repair, or uninstall Speedscale, speedctl, proxymock, or the Speedscale operator; asks how to get Speedscale running on a laptop or in a cluster; mentions `helm install speedscale-operator`; or hits `proxymock: command not found`, a failed pre-install job, or a webhook error. Trigger even if they name only one component - the skill decides which apply."
compatibility: Needs a shell (sh/bash, or PowerShell + WSL on Windows), curl, and network access to downloads.speedscale.com, app.speedscale.com, and speedscale.github.io. Cluster steps need a kubeconfig with cluster-admin-ish rights.
---

# Install Speedscale

Decide which parts apply before running anything. A laptop-only user needs
the local path below and nothing else. Only someone who wants to capture from
or replay into a Kubernetes cluster needs the cluster path.

| Component | What it is | Needed when |
| --- | --- | --- |
| `proxymock` | Local record / mock / replay CLI with a built-in MCP server and web UI | Any developer laptop, and anyone who wants their AI agent to use Speedscale |
| `speedctl` | CLI for the Speedscale cloud: snapshots, cloud replays, clusters | Cluster path, or cloud snapshots and reports |
| Speedscale Operator | Helm chart that captures traffic in Kubernetes and runs in-cluster replays | The user has a cluster to record from or replay into |

Both CLIs install to `~/.speedscale/` and share `~/.speedscale/config.json`
(the file proxymock reads; `config.yaml` is only an older-install fallback).
Authenticating one authenticates the other.

## Ground rules

- **Never print, echo, paste, or log an API key.** Keys live in
  `~/.speedscale/config.json` and the `SPEEDSCALE_API_KEY` environment
  variable. Pass them by reference (`"$SPEEDSCALE_API_KEY"`, a Kubernetes
  Secret, `scripts/apikey.sh` in a command substitution).
- **If a command opens a browser or waits on a prompt, hand it to the user.**
  `init` without `--api-key` does this on purpose. Nothing here should sit
  blocked on a TTY.
- **Do not run `speedctl install`.** It is an interactive wizard. Drive Helm
  directly.
- **User-space first, `sudo` only with permission.** Every Speedscale binary
  installs under `$HOME`. Ask before any `sudo`, and say why.
- **Idempotent.** Check before each step and skip what is done. Re-running on
  a healthy machine should change nothing.
- **A cluster is not yours to surprise.** Name the kube context and what will
  be created before touching it. Stop and confirm if the context looks like
  production; a first install belongs on dev or staging.

## Local path (laptop, no cluster)

Run `sh scripts/preflight.sh` first if you want a read-only report of what is
already installed (run scripts by absolute path from this skill's directory).

**1. Get a free API key.** `proxymock init` needs an account API key even for
local-only use, because `proxymock mcp install` refuses to run without an
initialized config. Signup is free: <https://app.speedscale.com/proxymock/signup>
(enterprise tenants: <https://app.speedscale.com/profile>). If the user has no
account yet, stop and send them there.

**2. Install proxymock.**

```bash
brew install speedscale/tap/proxymock          # Homebrew machine
sh -c "$(curl -Lfs https://downloads.speedscale.com/proxymock/install-proxymock)"   # macOS, Linux, WSL
```

Do not mix brew and script installs. The script does not edit `PATH`: add
`~/.speedscale` to the user's shell profile and tell them you did. Windows:
use WSL2. Pin a version with `-s vX.Y.Z`.

**Already installed? Upgrade it.** The skills and the MCP tools change with
each release, so an existing proxymock must be the latest release, not just
present. Re-run the install script: it checks the installed binary against the
latest release and replaces it only when they differ (Homebrew installs: `brew
upgrade speedscale/tap/proxymock`, and if the tap is older than the latest
release, switch to the script). Then check `proxymock version`. A version with
a `-g<hash>` suffix is a local development build: leave it and say so. After an
upgrade, re-run `proxymock mcp install --yes` (step 4) so the agent gets the
new tools and skills.

**3. Initialize with the key.** Default: ask the user to run `proxymock init`
in their own terminal (browser sign-in, writes the config). If
`SPEEDSCALE_API_KEY` is already set: `proxymock init --api-key
"$SPEEDSCALE_API_KEY" -y` (non-interactive init needs proxymock Pro or
Enterprise; free accounts use the browser flow once). Never ask the user to
paste a key into chat.

**4. Install the MCP server** into every detected coding agent:

```bash
proxymock mcp install --yes
```

For an agent that is not auto-detected, `proxymock mcp json` prints the
config block. `proxymock mcp install --http` serves Streamable HTTP for a
remote dev box or container; it defaults to port 7799 (clear of common app
ports and proxymock's own), and `proxymock mcp run --http` serves the same
default, so pass the same `--port <n>` to both to change it. Installs made by
older releases keep the URL they wrote (port 8080). The agent must be
restarted to load the server.

**5. The full skill set** (record, replay, tune, regression, load, chaos and
the rest) is bundled in the proxymock binary and needs no download.

- **Claude Code:** `proxymock mcp install --yes` already wrote every skill to
  `~/.claude/skills`. Nothing else to install.
- **Other agents (Codex, Cursor, Gemini, opencode, Kiro...):** either
  `npx skills add speedscale/skills` (needs Node.js; add `-y` when no human
  is present) or `proxymock mcp skills export --dir <that agent's skills dir>`
  (offline; safe to re-run after a proxymock upgrade).

Verify with `proxymock mcp skills list`: every skill shows `installed`
(`--dir <dir>` checks another agent's directory; `outdated` means a re-run of
`mcp install` or `mcp skills export` will refresh it). Anything else means
`mcp install` did not reach that agent.

**6. Prove it locally.** No cluster involved.

```bash
proxymock version          # prints the client, server, and "Config File:" path
proxymock mcp docs | head  # the MCP tool reference; tools are listed once the server loads
cd "$(mktemp -d)"
proxymock record -- curl -s -o /dev/null -w '%{http_code}\n' http://example.com   # ctrl-c after it prints 200
proxymock mock --in proxymock/recorded-* -- curl -s -o /dev/null -w '%{http_code}\n' http://example.com  # ctrl-c
grep -rh 'match=' proxymock/results | head -1     # expect match=HIT
```

Record writes `proxymock/recorded-<ts>/example.com/*.md`; the mock run writes
under `proxymock/results/` and tags the call `match=HIT`, meaning the answer
came from the recording, not the network. In an app's own directory use the
same commands with its start command after `--`. If `proxymock version` shows
no config file, step 3 did not finish.

## Cluster path (operator)

Only when the user wants capture or replay in Kubernetes. Do the local path
first, then follow `references/cluster-install.md`, which holds the exact
commands. In short:

1. **Discover.** `sh scripts/preflight.sh`, then resolve the mode, kube
   context, provider (EKS, GKE, AKS, minikube, kind, OpenShift), cluster name
   and any existing `speedscale-operator` release (upgrade it, never install a
   second one).
2. **Prerequisites and speedctl.** Install `kubectl`, `helm` and `speedctl`
   in user space if missing, then `speedctl check` and repeat the tenant name
   back to the user.
3. **Install.** `speedctl check operator --pre -n speedscale`, put the key in
   a Secret (`scripts/apikey.sh`), write a values file with the platform block
   from `references/operator.md`, then `helm upgrade --install
   speedscale-operator speedscale/speedscale-operator -n speedscale
   --create-namespace -f speedscale-values.yaml --wait --timeout 10m`.
4. **Verify.** `sh scripts/verify.sh speedscale`, then `speedctl infra
   inspectors` lists the cluster, and `cluster` with `action: status` from
   the MCP server reports operator health.

Failures: match the symptom in `references/troubleshooting.md` before
reinstalling. Upgrades and uninstall are in `references/cluster-install.md`;
CLI flags, config file layout and per-OS prerequisites in `references/cli.md`.

## Report

Finish with exactly this block, filled in, with these five headings and no
others. The user forwards it to a teammate.

```
### Result
- **Ran:** what ran, against what
- **Outcome:** pass, fail, or the headline number
- **Numbers:** the 2 to 4 metrics that matter for this skill
- **Artifacts:** paths the run wrote
- **Next:** one suggested next step, naming the skill or giving a prompt
```

- **Ran:** local or cluster, OS/arch, and the tenant or `KUBE_CONTEXT` ->
  cluster name.
- **Outcome:** `pass` when every check for the path passed, otherwise `fail`
  with the first failing check.
- **Numbers:** `proxymock` (and `speedctl`) versions, checks passed out of
  total, and the number of Speedscale skills installed.
- **Artifacts:** binaries and paths, `~/.speedscale/config.json`, any `PATH`
  edit, and the values file for a cluster install. Never list a key's value.
- **Next:** for example the prompt `record my app with proxymock and replay
  it`, or `run the run-snapshot-replay skill`. Add "restart your coding agent
  to load the MCP server and skills" when it applies.

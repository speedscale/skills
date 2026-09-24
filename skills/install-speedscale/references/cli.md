# CLI reference: speedctl and proxymock

Read this when Phase 1-3 of SKILL.md needs OS-specific commands, when a
binary is present but on the wrong path, or when authentication misbehaves.

## Contents

1. Prerequisites per OS
2. How the install scripts behave
3. Homebrew tap
4. Windows
5. Config file and API key locations
6. `init` flags and behaviours
7. Version pinning and upgrades

## 1. Prerequisites per OS

Install only what the preflight reported missing. Everything here is
user-space unless marked `sudo`.

### macOS

```bash
# Homebrew present:
brew install kubectl helm
# No Homebrew, and the user does not want it:
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/darwin/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')/kubectl"
chmod +x kubectl && mkdir -p ~/.local/bin && mv kubectl ~/.local/bin/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR="$HOME/.local/bin" USE_SUDO=false bash
```

`curl`, `openssl`, and `shasum` ship with macOS.

### Linux (Debian/Ubuntu, RHEL/Fedora, Alpine)

`curl` and one of `openssl`/`shasum` are required by the Speedscale install
scripts (checksum verification). If missing, they need the system package
manager and therefore `sudo`; ask first:

```bash
sudo apt-get update && sudo apt-get install -y curl openssl      # Debian/Ubuntu
sudo dnf install -y curl openssl                                  # RHEL/Fedora
sudo apk add curl openssl                                         # Alpine
```

kubectl and Helm without sudo:

```bash
mkdir -p ~/.local/bin
curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')/kubectl"
chmod +x kubectl && mv kubectl ~/.local/bin/
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | HELM_INSTALL_DIR="$HOME/.local/bin" USE_SUDO=false bash
```

Make sure `~/.local/bin` is on `PATH` (most modern distros add it when the
directory exists; a fresh login may be required). Distribution packages
(`apt install helm`) are frequently stale; prefer the script.

### Windows

Native PowerShell can run proxymock and kubectl/helm. speedctl requires WSL.

```powershell
winget install Kubernetes.kubectl Helm.Helm
```

Inside WSL follow the Linux column. A kubeconfig on the Windows side can be
reused from WSL via `export KUBECONFIG=/mnt/c/Users/<name>/.kube/config`.

## 2. How the install scripts behave

Both scripts (`downloads.speedscale.com/speedctl/install` and
`downloads.speedscale.com/proxymock/install-proxymock`) are plain POSIX `sh`
and are safe to inspect before running: `curl -Lfs <url> | less`.

What they do, in order:

1. Detect OS (`Darwin`, `Linux`; `CYGWIN/MINGW/MSYS` is Windows) and arch
   (`x86_64` -> `amd64`, `arm*`/`aarch64` -> `arm64`). Anything else exits 1.
2. Require `openssl` or `shasum` for checksum verification.
3. Download `<name>-<os>-<arch>` (or a pinned `<version>/<name>-<os>-<arch>`)
   into a temp dir, fetch the `.sha256`, compare, abort on mismatch.
4. Move it to `$INSTALLROOT/<name>` (`INSTALLROOT` defaults to
   `~/.speedscale`) and `chmod +x`. No sudo, no system paths.
5. If the binary already existed and matched the latest checksum **and** a
   config file exists, print "already the current version" and exit 0.
6. `happy_exit`: if `~/.speedscale/config.yaml` does not exist and either
   `SPEEDSCALE_API_KEY` or `SPEEDSCALE_EMAIL` is set, or the shell is
   interactive, it runs `<name> init` for you. From a non-interactive agent
   shell with neither variable set it simply exits, so you run `init` yourself
   in Phase 3.

Consequences worth knowing:

- The scripts never modify `PATH`. You must add `~/.speedscale` yourself.
- Setting `SPEEDSCALE_API_KEY` before running the script makes it self-initialize non-interactively. In an agent session, run `speedctl check` afterward to verify registration without putting the key in process arguments.
- Version pin: `sh -c "$(curl -Lfs <url>)" -s v2.5.978`. Match the operator
  chart's `appVersion` when a customer wants CLI and cluster in lockstep;
  otherwise latest is fine, the CLI is backward compatible with older
  operators.
- Re-running the script is the upgrade path for proxymock. speedctl also has
  `speedctl update [version]`.

## 3. Homebrew tap

```bash
brew install speedscale/tap/speedctl
brew install speedscale/tap/proxymock
```

brew installs into its own prefix and handles `PATH`. Do not also run the
script; two copies of the binary in different directories is the most common
"I upgraded but the version did not change" complaint. If both exist,
`which -a speedctl` shows the order; remove the one the user did not intend.

## 4. Windows

speedctl: use WSL. proxymock: native binary.

```powershell
mkdir -Force $env:USERPROFILE\.speedscale
curl.exe -L "https://downloads.speedscale.com/proxymock/proxymock.exe" -o $env:USERPROFILE\.speedscale\proxymock.exe
# user-scope PATH, no admin needed:
[Environment]::SetEnvironmentVariable("Path", $env:Path + ";" + $env:USERPROFILE + "\.speedscale", "User")
```

Restart the terminal, then `proxymock init`. Windows MCP clients sometimes
fail to spawn `proxymock.exe` as a child process; if the client hangs on
startup, run `proxymock mcp run --http` and configure the client with the
HTTP URL from `proxymock mcp json --http`.

## 5. Config file and API key locations

- Home: `~/.speedscale` unless `SPEEDSCALE_HOME` is set (`--home` on `init`).
- Config: `config.json` preferred when present, otherwise `config.yaml`. A new `init` writes YAML unless the config is converted to JSON. Structure: `current-context`, `contexts[]` (each with `name`,
  `tenant`, `app-url`), `tenants[]` (each with `name`, `apikey`). The API key
  for the active context is the `apikey` of the tenant whose `name` equals
  the current context's `tenant`. `scripts/apikey.sh` does this lookup.
- Backups: `init` renames an existing config to `config.<unixtime>.yaml`
  unless `--overwrite`.
- Env override: `SPEEDSCALE_API_KEY` (and `SPEEDSCALE_APP_URL`) take effect
  for both CLIs without a config file; `init` writes them into the rcfile
  unless `--no-rcfile-update`.
- Certificates: `~/.speedscale/certs/` is created by `init` (`EnsureTLSCerts`)
  and used by proxymock for TLS interception. Missing certs after a partial
  init are fixed by re-running `init`.

## 6. `init` flags and behaviours

```
speedctl init | proxymock init
  --api-key <key>        non-interactive; exposes the key in process arguments, so use environment-based registration instead
  -y, --yes              answer yes to optional prompts (rcfile update, MCP install into detected clients)
  --home <dir>           speedscale home (default ~/.speedscale)
  --rcfile <file>        shell rc to update (default: current shell's)
  --no-rcfile-update     do not touch the rcfile
  --overwrite            replace an existing config instead of backing it up
  --quiet                only fatal errors; ALSO suppresses the MCP client install step
  --app-url <host>       for non-default Speedscale environments (BYOC, on-prem)
```

Behaviours:

- Browser flow requires a human; it cannot be completed from an agent shell.
  Ask the user to run it in their terminal, then continue.
- Non-interactive registration is a paid feature for proxymock (Pro or Enterprise). Set `SPEEDSCALE_API_KEY` and run `speedctl check` from a clean Speedscale home. Free-tier users must use the browser flow once; after that the config file works everywhere.
- After auth, `init` detects coding agents (Cursor, Claude Desktop, Claude
  Code, VS Code, Gemini CLI, OpenCode, Codex, Kiro) and offers to add the
  proxymock MCP server. `-y` accepts all; `--quiet` skips the step entirely.
- Enterprise users whose org already has a tenant are auto-joined when they
  sign in with their corporate email; a tenant that "looks empty" usually
  means the email domain is not mapped yet (support@speedscale.com).

Verification that does not leak the key:

```bash
speedctl check                 # config + API reachability + tenant summary
speedctl config current-context
```

## 7. Version pinning and upgrades

| Action | Command |
| --- | --- |
| Show versions | `speedctl version` (client + cloud), `proxymock version` |
| Upgrade speedctl | `speedctl update` or `brew upgrade speedctl` |
| Pin speedctl | `speedctl update v2.5.978` or the script with `-s v2.5.978` |
| Upgrade proxymock | re-run the install script or `brew upgrade proxymock` |
| Release notes | https://docs.speedscale.com/reference/release-notes/ |

`speedctl` warns when the client is older than the cloud; that is a nudge,
not a failure. Clusters and CLIs can differ by many patch versions.

#!/bin/sh
# preflight.sh - read-only report of everything the install-speedscale skill
# needs to decide what to do. Never modifies the machine or the cluster,
# never prints secrets, always exits 0 so the caller reads the report rather
# than a status code.
#
# Usage: sh preflight.sh [kube-context]

ctx_override="${1:-}"
SS_HOME="${SPEEDSCALE_HOME:-$HOME/.speedscale}"

say() { printf '%s\n' "$*"; }
hdr() { printf '\n== %s ==\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
ver() { # ver <label> <cmd...> ; prints first line of output or MISSING
  label=$1; shift
  if have "$1"; then
    out=$("$@" 2>&1 | head -n 1)
    say "$label: $out  ($(command -v "$1"))"
  else
    say "$label: MISSING"
  fi
}

hdr "machine"
say "os: $(uname -s) $(uname -r)"
say "arch: $(uname -m)"
say "shell: ${SHELL:-unknown}"
say "home: $HOME"
say "speedscale_home: $SS_HOME"
case "$(uname -s)" in
  Darwin) say "platform: macos" ;;
  Linux)  if grep -qi microsoft /proc/version 2>/dev/null; then say "platform: wsl"; else say "platform: linux"; fi ;;
  CYGWIN*|MINGW*|MSYS*) say "platform: windows-shell (speedctl needs WSL; proxymock has a native .exe)" ;;
  *) say "platform: unsupported ($(uname -s))" ;;
esac

hdr "package managers"
for pm in brew apt-get dnf yum apk zypper pacman winget choco; do
  have "$pm" && say "$pm: $(command -v "$pm")"
done
have sudo && say "sudo: available (ask before using)" || say "sudo: not available"

hdr "base tools"
ver curl curl --version
if have openssl; then say "checksum: openssl ($(command -v openssl))"; elif have shasum; then say "checksum: shasum ($(command -v shasum))"; else say "checksum: MISSING (install openssl or shasum; the Speedscale install scripts require one)"; fi
ver git git --version
ver python3 python3 --version
ver jq jq --version

hdr "kubernetes tools"
if have kubectl; then
  say "kubectl: $(kubectl version --client -o json 2>/dev/null | sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' | head -n1)  ($(command -v kubectl))"
else
  say "kubectl: MISSING"
fi
if have helm; then
  say "helm: $(helm version --short 2>/dev/null)  ($(command -v helm))"
  if helm repo list 2>/dev/null | grep -q 'speedscale.github.io/operator-helm'; then say "helm_repo_speedscale: present"; else say "helm_repo_speedscale: absent"; fi
else
  say "helm: MISSING"
fi

hdr "speedscale clis"
for bin in speedctl proxymock; do
  if have "$bin"; then
    v=$("$bin" version --client 2>/dev/null | head -n1)
    [ -z "$v" ] && v=$("$bin" version 2>/dev/null | head -n1)
    say "$bin: $v  ($(command -v "$bin"))"
    n=$(command -v -a "$bin" 2>/dev/null | sort -u | wc -l | tr -d ' ')
    [ "$n" -gt 1 ] && say "$bin: WARNING $n copies on PATH: $(command -v -a "$bin" | sort -u | tr '\n' ' ')"
  elif [ -x "$SS_HOME/$bin" ]; then
    say "$bin: installed at $SS_HOME/$bin but NOT on PATH"
  else
    say "$bin: MISSING"
  fi
done
case ":$PATH:" in *":$SS_HOME:"*) say "path_has_speedscale_home: yes" ;; *) say "path_has_speedscale_home: no" ;; esac

hdr "speedscale auth"
if [ -f "$SS_HOME/config.json" ]; then say "config: $SS_HOME/config.json"
elif [ -f "$SS_HOME/config.yaml" ]; then say "config: $SS_HOME/config.yaml"
else say "config: none (run init in Phase 3)"; fi
[ -n "${SPEEDSCALE_API_KEY:-}" ] && say "SPEEDSCALE_API_KEY: set (value not shown)" || say "SPEEDSCALE_API_KEY: not set"
[ -n "${SPEEDSCALE_APP_URL:-}" ] && say "SPEEDSCALE_APP_URL: $SPEEDSCALE_APP_URL"
if have speedctl && { [ -f "$SS_HOME/config.json" ] || [ -f "$SS_HOME/config.yaml" ]; }; then
  say "current_context: $(speedctl config current-context 2>/dev/null | head -n1)"
  say "app_url: $(sh "$(dirname "$0")/apikey.sh" --app-url 2>/dev/null || echo unknown)  (the operator's appUrl and SPEEDSCALE_APP_URL must match this)"
  say "versions (client vs cloud): $(speedctl version 2>/dev/null | head -n1)"
fi
[ -d "$SS_HOME/certs" ] && say "certs: present" || say "certs: absent (created by init)"

hdr "kubernetes cluster"
if ! have kubectl; then
  say "cluster: skipped (no kubectl)"
else
  say "KUBECONFIG: ${KUBECONFIG:-~/.kube/config}"
  say "contexts: $(kubectl config get-contexts -o name 2>/dev/null | tr '\n' ' ')"
  ctx=${ctx_override:-$(kubectl config current-context 2>/dev/null)}
  if [ -z "$ctx" ]; then
    say "current_context: none"
  else
    K="kubectl --context=$ctx --request-timeout=10s"
    say "current_context: $ctx"
    say "server: $($K config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
    # /version only answers when the API server is reachable; 'kubectl version'
    # would still print the client version and look like success.
    sv=$($K get --raw /version 2>/dev/null | sed -n 's/.*"gitVersion": *"\(v[^"]*\)".*/\1/p' | head -n1)
    if [ -z "$sv" ]; then
      say "reachable: NO ($($K get --raw /version 2>&1 | head -n1 | cut -c1-120))"
      say "cluster mode is not possible until kubectl can reach this context (is the cluster running? VPN? kubeconfig expired?)"
    else
      say "reachable: yes"
      say "server_version: $sv (Speedscale needs 1.19+)"
      case "$ctx" in
        *prod*|*prd*|*live*) say "WARNING: context name looks like production; confirm with the user before installing" ;;
      esac

      # provider guess from providerID prefixes and well-known labels
      pids=$($K get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}' 2>/dev/null | cut -d: -f1 | sort -u | tr '\n' ' ')
      labels=$($K get nodes -o jsonpath='{range .items[*]}{.metadata.labels}{"\n"}{end}' 2>/dev/null)
      guess=other
      case "$pids" in *aws*) guess=eks ;; *gce*) guess=gke ;; *azure*) guess=aks ;; *k3s*) guess=k3s ;; *kind*) guess=kind ;; esac
      echo "$labels" | grep -q 'eks.amazonaws.com' && guess=eks
      echo "$labels" | grep -q 'cloud.google.com/gke' && guess=gke
      echo "$labels" | grep -q 'kubernetes.azure.com' && guess=aks
      echo "$labels" | grep -q 'node.openshift.io' && guess=openshift
      echo "$labels" | grep -q 'minikube.k8s.io' && guess=minikube
      echo "$labels" | grep -q 'gke-autopilot\|autopilot.gke.io' && guess=gke-autopilot
      echo "$labels" | grep -q 'eks.amazonaws.com/compute-type.*fargate' && say "note: EKS Fargate nodes present (nettap cannot run there; cloudProvider=aws excludes them)"
      say "provider_guess: $guess"

      say "nodes (name arch kernel os):"
      $K get nodes -o jsonpath='{range .items[*]}{"  "}{.metadata.name}{" "}{.status.nodeInfo.architecture}{" "}{.status.nodeInfo.kernelVersion}{" "}{.status.nodeInfo.osImage}{"\n"}{end}' 2>/dev/null
      # eBPF readiness: x86_64 >= 5.15, arm64 >= 6.0
      $K get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.nodeInfo.architecture}{" "}{.status.nodeInfo.kernelVersion}{"\n"}{end}' 2>/dev/null | awk '
        { split($3, k, "[.-]"); major=k[1]+0; minor=k[2]+0
          ok = ($2=="amd64" && (major>5 || (major==5 && minor>=15))) || ($2=="arm64" && major>=6)
          if (ok) pass++; else { fail++; failed=failed " " $1 } }
        END { printf "ebpf_ready_nodes: %d pass, %d fail%s\n", pass, fail, (fail?" (" failed " )":"")
              if (fail==0 && pass>0) print "ebpf_recommendation: enabled: true"; else print "ebpf_recommendation: enabled: false (or exclude failing nodes)" }'

      say "rbac (create):"
      for r in customresourcedefinitions clusterroles clusterrolebindings mutatingwebhookconfigurations validatingwebhookconfigurations namespaces; do
        say "  $r: $($K auth can-i create "$r" 2>/dev/null)"
      done
      for r in deployments secrets jobs configmaps roles rolebindings services serviceaccounts daemonsets; do
        say "  speedscale/$r: $($K auth can-i create "$r" -n speedscale 2>/dev/null)"
      done

      say "existing install:"
      if $K get ns speedscale >/dev/null 2>&1; then say "  namespace speedscale: exists"; else say "  namespace speedscale: absent"; fi
      if have helm; then
        rel=$(helm --kube-context "$ctx" list -A --filter '^speedscale-operator$' -o json 2>/dev/null)
        if [ -n "$rel" ] && [ "$rel" != "[]" ]; then
          rns=$(printf '%s' "$rel" | sed -n 's/.*"namespace": *"\([^"]*\)".*/\1/p' | head -n1)
          say "  helm release: $(for f in name namespace status chart app_version; do printf '%s=%s ' "$f" "$(printf '%s' "$rel" | sed -n 's/.*"'"$f"'": *"\([^"]*\)".*/\1/p' | head -n1)"; done)"
          say "  existing clusterName: $(helm --kube-context "$ctx" -n "$rns" get values speedscale-operator -o json 2>/dev/null | sed -n 's/.*"clusterName": *"\([^"]*\)".*/\1/p' | head -n1)  (keep it on upgrade)"
        else say "  helm release: none"; fi
      fi
      $K get crd trafficreplays.speedscale.com >/dev/null 2>&1 && say "  crd trafficreplays.speedscale.com: exists" || say "  crd trafficreplays.speedscale.com: absent"
      wh=$($K get mutatingwebhookconfigurations,validatingwebhookconfigurations -o name 2>/dev/null | grep -c speedscale)
      say "  speedscale webhook configurations: $wh"
      [ "$wh" -gt 0 ] && ! $K get deploy -n speedscale speedscale-operator >/dev/null 2>&1 && say "  WARNING: webhooks exist without an operator deployment; see troubleshooting section 6"
      $K get deploy -n speedscale 2>/dev/null | sed 's/^/  /'
    fi
  fi
fi

hdr "coding agents detected"
[ -d "$HOME/.cursor" ] && say "cursor: ~/.cursor"
{ [ -d "$HOME/.claude" ] || [ -f "$HOME/.claude.json" ]; } && say "claude-code: ~/.claude"
[ -f "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ] && say "claude-desktop: present"
[ -f "$HOME/.config/Claude/claude_desktop_config.json" ] && say "claude-desktop: present"
[ -d "$HOME/.codex" ] && say "codex: ~/.codex"
[ -d "$HOME/.gemini" ] && say "gemini-cli: ~/.gemini"
[ -d "$HOME/.config/opencode" ] && say "opencode: ~/.config/opencode"
[ -d "$HOME/.kiro" ] && say "kiro: ~/.kiro"
{ [ -d "$HOME/Library/Application Support/Code/User" ] || [ -d "$HOME/.config/Code/User" ]; } && say "vscode: present"
have claude && say "claude cli: $(command -v claude)"

hdr "suggested mode"
if have kubectl && [ -n "${sv:-}" ]; then say "cluster (reachable cluster $ctx, provider $guess)"; else say "local (no reachable cluster; install CLIs + agent wiring only)"; fi
exit 0

#!/bin/sh
# verify.sh - post-install checks for the Speedscale operator.
# Usage: sh verify.sh [namespace] [kube-context]
# Exit 0 when every check passes, 1 otherwise. Read-only.

ns="${1:-speedscale}"
ctx="${2:-}"
K="kubectl --request-timeout=15s"
[ -n "$ctx" ] && K="$K --context=$ctx"
H="helm"; [ -n "$ctx" ] && H="helm --kube-context=$ctx"
fail=0
pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
failed() { printf 'FAIL  %s\n' "$*"; fail=1; }
have() { command -v "$1" >/dev/null 2>&1; }

have kubectl || { failed "kubectl not found"; exit 1; }
$K get ns "$ns" >/dev/null 2>&1 || { failed "namespace $ns does not exist"; exit 1; }

# 1. helm release
if have helm; then
  # 'helm list' JSON is flat; 'helm status' JSON nests resource conditions whose
  # "status" fields would be matched first.
  rel=$($H -n "$ns" list --filter '^speedscale-operator$' -o json 2>/dev/null)
  st=$(printf '%s' "$rel" | sed -n 's/.*"status": *"\([^"]*\)".*/\1/p' | head -n1)
  case "$st" in
    deployed) pass "helm release speedscale-operator is deployed ($(printf '%s' "$rel" | sed -n 's/.*"chart": *"\([^"]*\)".*/\1/p'))" ;;
    "") warn "no helm release named speedscale-operator in $ns (installed another way?)" ;;
    *) failed "helm release status is '$st'" ;;
  esac
fi

# 2. pre-install job leftovers
for j in $($K -n "$ns" get jobs -o name 2>/dev/null | grep pre-install); do
  if $K -n "$ns" get "$j" -o jsonpath='{.status.failed}' 2>/dev/null | grep -q '[1-9]'; then
    failed "$j failed; last log lines:"; $K -n "$ns" logs "$j" --tail=20 2>/dev/null | sed 's/^/      /'
  fi
done

# 3. CRD
$K get crd trafficreplays.speedscale.com >/dev/null 2>&1 && pass "crd trafficreplays.speedscale.com present" || failed "crd trafficreplays.speedscale.com missing"

# 4. deployments (operator is created by helm; forwarder/inspector by the operator, so give them time)
check_deploy() { # name required(1/0)
  name=$1; req=$2; i=0
  while [ $i -lt 24 ]; do
    if $K -n "$ns" get deploy "$name" >/dev/null 2>&1; then
      avail=$($K -n "$ns" get deploy "$name" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
      want=$($K -n "$ns" get deploy "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null)
      if [ "${avail:-0}" -ge "${want:-1}" ] 2>/dev/null && [ "${avail:-0}" -gt 0 ]; then pass "deployment $name available ($avail/$want)"; return; fi
    fi
    i=$((i+1)); sleep 5
  done
  if [ "$req" = 1 ]; then failed "deployment $name not available after 120s"; else warn "deployment $name not available after 120s (optional component)"; fi
  $K -n "$ns" get pods -l "app=$name" 2>/dev/null | sed 's/^/      /'
}
check_deploy speedscale-operator 1
check_deploy speedscale-forwarder 1
check_deploy speedscale-inspector 0

# 5. webhooks
for w in mutatingwebhookconfigurations/speedscale-operator mutatingwebhookconfigurations/speedscale-operator-replay validatingwebhookconfigurations/speedscale-operator-replay; do
  $K get "$w" >/dev/null 2>&1 && pass "$w present" || failed "$w missing"
done

# 6. nettap (eBPF) when present
ds=$($K -n "$ns" get daemonset -o name 2>/dev/null | grep nettap | head -n1)
if [ -n "$ds" ]; then
  d=$($K -n "$ns" get "$ds" -o jsonpath='{.status.desiredNumberScheduled}')
  r=$($K -n "$ns" get "$ds" -o jsonpath='{.status.numberReady}')
  if [ "${r:-0}" -eq "${d:-0}" ] && [ "${d:-0}" -gt 0 ]; then pass "$ds ready ($r/$d)"; else failed "$ds ready $r/$d (see troubleshooting section 8)"; fi
else
  warn "no nettap daemonset (ebpf.enabled is false; sidecar capture only)"
fi

# 7. unhealthy pods
bad=$($K -n "$ns" get pods --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" && $3!="Succeeded" {print $1" "$3}')
[ -n "$bad" ] && { failed "pods not running:"; echo "$bad" | sed 's/^/      /'; } || pass "all pods in $ns are Running/Completed"

# 8. operator self-check / registration errors in recent logs
if $K -n "$ns" logs deploy/speedscale-operator --tail=200 2>/dev/null | grep -q 'self-check failed'; then
  failed "operator log contains 'self-check failed' (troubleshooting section 5)"
fi

# 9. speedctl view (cloud-side registration)
if have speedctl; then
  out=$(speedctl check operator -n "$ns" 2>&1)
  if echo "$out" | grep -q 'All checks were successful'; then pass "speedctl check operator: all checks successful"; else failed "speedctl check operator reported problems:"; echo "$out" | tail -n 25 | sed 's/^/      /'; fi
else
  warn "speedctl not installed; skipped cloud-side registration check"
fi

if [ $fail -eq 0 ]; then printf '\nRESULT: PASS\n'; else printf '\nRESULT: FAIL\n'; fi
exit $fail

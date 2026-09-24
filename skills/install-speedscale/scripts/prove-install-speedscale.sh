#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/bin" "$tmp/empty"

cat > "$tmp/home/config.yaml" <<'YAML'
current-context: second
contexts:
  - name: first
    app-url: first.speedscale.com
    tenant: first-tenant
  - name: second
    app-url: second.speedscale.com
    tenant: second-tenant
tenants:
  - name: first-tenant
    apikey: dummy-first-key
  - name: second-tenant
    apikey: dummy-second-key
YAML

[[ "$(SPEEDSCALE_HOME="$tmp/home" sh "$script_dir/apikey.sh")" == dummy-second-key ]]
[[ "$(SPEEDSCALE_HOME="$tmp/home" sh "$script_dir/apikey.sh" --app-url)" == second.speedscale.com ]]
[[ "$(SPEEDSCALE_HOME="$tmp/home" SPEEDSCALE_CONTEXT=first sh "$script_dir/apikey.sh")" == dummy-first-key ]]
[[ "$(SPEEDSCALE_HOME="$tmp/empty" SPEEDSCALE_API_KEY=dummy-env-key sh "$script_dir/apikey.sh" --app-url)" == app.speedscale.com ]]

cat > "$tmp/bin/kubectl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_ARGS"
case " $* " in
  *' create secret '*) cat > "$STUB_STDIN"; printf 'kind: Secret\n' ;;
  *' apply -f - '*) cat > "$STUB_MANIFEST"; printf 'secret/speedscale-apikey configured\n' ;;
  *' config view '*) printf 'apiVersion: v1\nkind: Config\ncurrent-context: selected-context\n' ;;
  *) exit 2 ;;
esac
SH
cat > "$tmp/bin/speedctl" <<'SH'
#!/bin/sh
[ -n "${KUBECONFIG:-}" ] && grep -q 'current-context: selected-context' "$KUBECONFIG" || exit 1
printf 'All checks were successful\n'
SH
chmod +x "$tmp/bin/kubectl" "$tmp/bin/speedctl"

export STUB_ARGS="$tmp/args" STUB_STDIN="$tmp/stdin" STUB_MANIFEST="$tmp/manifest"
PATH="$tmp/bin:$PATH" SPEEDSCALE_HOME="$tmp/home" bash "$script_dir/create-apikey-secret.sh" speedscale selected-context > "$tmp/out"
[[ "$(cat "$tmp/stdin")" == dummy-second-key ]]
! grep -q 'dummy-second-key' "$tmp/args"
grep -q -- '--context selected-context' "$tmp/args"

PATH="$tmp/bin:$PATH" sh "$script_dir/with-kube-context.sh" selected-context speedctl check operator > "$tmp/check"
grep -q 'All checks were successful' "$tmp/check"

rm -f "$tmp/args"
if PATH="$tmp/bin:$PATH" SPEEDSCALE_HOME="$tmp/empty" bash "$script_dir/create-apikey-secret.sh" speedscale selected-context > "$tmp/out" 2>&1; then
  echo 'missing key was accepted' >&2
  exit 1
fi
[[ ! -e "$tmp/args" ]]

echo 'PASS: config lookup, stdin Secret creation, context selection, and missing-key rejection'

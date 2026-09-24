#!/usr/bin/env bash
set +x
set -euo pipefail

ns="${1:-speedscale}"
ctx="${2:-}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

api_key="$(sh "$script_dir/apikey.sh")" || exit 1
[[ -n "$api_key" ]] || { echo "API key is empty" >&2; exit 1; }
app_url="$(sh "$script_dir/apikey.sh" --app-url)" || exit 1
[[ -n "$app_url" ]] || { echo "Speedscale app URL is empty" >&2; exit 1; }

kubectl_args=()
[[ -z "$ctx" ]] || kubectl_args+=(--context "$ctx")

# The key passes through stdin; it never appears in a kubectl argument or output.
printf '%s' "$api_key" |
  kubectl "${kubectl_args[@]}" -n "$ns" create secret generic speedscale-apikey \
    --from-file=SPEEDSCALE_API_KEY=/dev/stdin \
    --from-literal=SPEEDSCALE_APP_URL="$app_url" \
    --dry-run=client -o yaml |
  kubectl "${kubectl_args[@]}" apply -f -

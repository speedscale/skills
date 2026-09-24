#!/bin/sh
set -eu

ctx=${1:-}
shift
[ "$#" -gt 0 ] || { echo "usage: with-kube-context.sh CONTEXT COMMAND [ARG...]" >&2; exit 2; }
if [ -z "$ctx" ]; then exec "$@"; fi

kubeconfig_tmp=$(mktemp "${TMPDIR:-/tmp}/speedscale-context.XXXXXX")
trap 'rm -f "$kubeconfig_tmp"' EXIT
trap 'exit 1' HUP INT TERM
chmod 600 "$kubeconfig_tmp"
kubectl --context="$ctx" config view --raw --minify --flatten > "$kubeconfig_tmp"
KUBECONFIG="$kubeconfig_tmp" "$@"

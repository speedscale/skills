#!/usr/bin/env bash
# Save and restore the workspace state a tuning change touches, so any
# iteration can be reverted exactly: the tuning blueprints and test configs.
# Recorded traffic is never copied or changed.
#
#   checkpoint.sh save    <workspace> <label>
#   checkpoint.sh restore <workspace> <label>
#   checkpoint.sh list    <workspace>
#
# <workspace> is the directory holding proxymock/ (usually the repo root).
# Checkpoints live in <workspace>/proxymock/tuning/checkpoints/<label>/.
set -euo pipefail

ACTION="${1:-}"
WS="${2:-}"
LABEL="${3:-}"
usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ -n "$ACTION" ] && [ -n "$WS" ] || usage

PM="$WS/proxymock"
[ -d "$PM" ] || { echo "no proxymock directory under $WS" >&2; exit 2; }
ROOT="$PM/tuning/checkpoints"
STATE_DIRS=(blueprints testconfigs)

case "$ACTION" in
  save)
    [ -n "$LABEL" ] || usage
    dest="$ROOT/$LABEL"
    rm -rf "$dest"
    mkdir -p "$dest"
    for d in "${STATE_DIRS[@]}"; do
      if [ -d "$PM/$d" ]; then
        cp -R "$PM/$d" "$dest/$d"
      else
        # Remember that it did not exist, so restore removes it again.
        touch "$dest/.absent-$d"
      fi
    done
    echo "saved $dest"
    ;;
  restore)
    [ -n "$LABEL" ] || usage
    src="$ROOT/$LABEL"
    [ -d "$src" ] || { echo "no checkpoint $LABEL (have: $(ls "$ROOT" 2>/dev/null | tr '\n' ' '))" >&2; exit 1; }
    for d in "${STATE_DIRS[@]}"; do
      rm -rf "${PM:?}/$d"
      if [ -d "$src/$d" ]; then
        cp -R "$src/$d" "$PM/$d"
      fi
    done
    echo "restored $src"
    ;;
  list)
    ls -1t "$ROOT" 2>/dev/null || true
    ;;
  *)
    usage
    ;;
esac

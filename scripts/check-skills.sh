#!/bin/sh
# Validates every skill: SKILL.md present, frontmatter with name matching the
# directory and a non-empty description, helper scripts parse and are
# executable. Run from the repo root; exits 1 on the first problem.
set -eu
status=0
for dir in skills/*/; do
  name=$(basename "$dir")
  f="$dir/SKILL.md"
  [ -f "$f" ] || { echo "FAIL $name: missing SKILL.md"; status=1; continue; }
  head -n1 "$f" | grep -q '^---$' || { echo "FAIL $name: no frontmatter"; status=1; }
  grep -q "^name: $name\$" "$f" || { echo "FAIL $name: frontmatter name does not match directory"; status=1; }
  grep -q '^description: .\{20,\}' "$f" || { echo "FAIL $name: description missing or too short"; status=1; }
  for s in "$dir"scripts/*.sh; do
    [ -e "$s" ] || continue
    sh -n "$s" || { echo "FAIL $name: $s does not parse"; status=1; }
    [ -x "$s" ] || { echo "FAIL $name: $s is not executable"; status=1; }
  done
  echo "ok   $name"
done
python3 -c 'import json,sys; [json.load(open(p)) for p in sys.argv[1:]]' .claude-plugin/marketplace.json .claude-plugin/plugin.json && echo "ok   plugin manifests parse"
exit $status

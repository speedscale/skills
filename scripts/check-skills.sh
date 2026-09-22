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
  # description may be a one-liner or a YAML block scalar (">" / "|") continued on the next lines
  awk 'BEGIN{ok=0} /^---$/{fm++; next} fm==1 && /^description: *[>|]/{blk=1; next} fm==1 && blk && /^  ./{ok=1} fm==1 && /^description: .{20,}/{ok=1} END{exit ok?0:1}' "$f" \
    || { echo "FAIL $name: description missing or too short"; status=1; }
  for s in "$dir"scripts/*.sh; do
    [ -e "$s" ] || continue
    # parse with the interpreter the script declares; bash scripts use process substitution
    if head -n1 "$s" | grep -q bash; then bash -n "$s"; else sh -n "$s"; fi || { echo "FAIL $name: $s does not parse"; status=1; }
    [ -x "$s" ] || { echo "FAIL $name: $s is not executable"; status=1; }
  done
  echo "ok   $name"
done
python3 -c 'import json,sys; [json.load(open(p)) for p in sys.argv[1:]]' .claude-plugin/marketplace.json .claude-plugin/plugin.json && echo "ok   plugin manifests parse"
exit $status

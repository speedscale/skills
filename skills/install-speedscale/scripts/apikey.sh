#!/bin/sh
# apikey.sh - read the current context's API key or app URL for use by local
# scripts. Do not pass its output as a command argument.
# Order: $SPEEDSCALE_API_KEY, then ~/.speedscale/config.json, then config.yaml.
# Optional: SPEEDSCALE_CONTEXT=<name> selects a context other than current.
# With --app-url it prints the context's Speedscale host (app.speedscale.com
# for most tenants) instead of the key, for SPEEDSCALE_APP_URL / appUrl.
# Exit 1 with a message on stderr when nothing can be found.

field=apikey
[ "${1:-}" = "--app-url" ] && field=appurl

if [ "$field" = appurl ] && [ -n "${SPEEDSCALE_APP_URL:-}" ]; then printf '%s' "$SPEEDSCALE_APP_URL"; exit 0; fi
if [ "$field" = apikey ] && [ -n "${SPEEDSCALE_API_KEY:-}" ]; then printf '%s' "$SPEEDSCALE_API_KEY"; exit 0; fi

home="${SPEEDSCALE_HOME:-$HOME/.speedscale}"
want="${SPEEDSCALE_CONTEXT:-}"

if [ -f "$home/config.json" ]; then
  cfg="$home/config.json"
  if command -v python3 >/dev/null 2>&1; then
    key=$(python3 - "$cfg" "$want" "$field" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
name = sys.argv[2] or cfg.get("current-context", "")
ctx = next((c for c in cfg.get("contexts", []) if c.get("name") == name), None)
if ctx is None:
    sys.exit(1)
if sys.argv[3] == "appurl":
    print(ctx.get("app-url") or "app.speedscale.com", end="")
    sys.exit(0)
tenant = next((t for t in cfg.get("tenants", []) if t.get("name") == ctx.get("tenant")), None)
if not tenant or not tenant.get("apikey"):
    sys.exit(1)
print(tenant["apikey"], end="")
PY
)
  elif command -v jq >/dev/null 2>&1; then
    key=$(jq -r --arg want "$want" --arg field "$field" '
      (if $want == "" then .["current-context"] else $want end) as $n
      | (.contexts[] | select(.name == $n)) as $c
      | if $field == "appurl" then ($c["app-url"] // "app.speedscale.com")
        else (.tenants[] | select(.name == $c.tenant) | .apikey // empty) end' "$cfg" | head -n1)
  else
    echo "apikey.sh: need python3 or jq to read $cfg" >&2; exit 1
  fi
elif [ -f "$home/config.yaml" ]; then
  cfg="$home/config.yaml"
  # The CLI's YAML lists are indented beneath contexts: and tenants:.
  key=$(awk -v want="$want" -v field="$field" '
    /^current-context:/ && want=="" { want=$2; gsub(/"/,"",want) }
    /^contexts:/ { sec="ctx"; next }
    /^tenants:/ { sec="ten"; next }
    /^[a-z][^:]*:/ { sec="" }
    sec=="ctx" && /^[[:space:]]*-[[:space:]]*name:/ { cname=$NF; gsub(/"/,"",cname) }
    sec=="ctx" && /^[[:space:]]*app-url:/ && cname==want { appurl=$NF; gsub(/"/,"",appurl) }
    sec=="ctx" && /^[[:space:]]*tenant:/ && cname==want { tenant=$NF; gsub(/"/,"",tenant) }
    sec=="ten" && /^[[:space:]]*-[[:space:]]*name:/ { tname=$NF; gsub(/"/,"",tname) }
    sec=="ten" && /^[[:space:]]*apikey:/ && tname!="" { tenantkey[tname]=$NF; gsub(/"/,"",tenantkey[tname]) }
    END {
      if (field=="appurl" && tenant!="") printf "%s", (appurl==""?"app.speedscale.com":appurl)
      if (field=="apikey" && tenant!="") printf "%s", tenantkey[tenant]
    }
  ' "$cfg")
else
  if [ "$field" = appurl ]; then printf '%s' app.speedscale.com; exit 0; fi
  echo "apikey.sh: no Speedscale config in $home; run 'speedctl init' first or export SPEEDSCALE_API_KEY" >&2; exit 1
fi

if [ -z "$key" ]; then echo "apikey.sh: no $field found for context '${want:-current}' in $cfg" >&2; exit 1; fi
printf '%s' "$key"

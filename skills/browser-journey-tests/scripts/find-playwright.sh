#!/usr/bin/env bash
# Inventory the Playwright tests in a repository and flag what will not
# survive Speedscale's browser runner (proxymock replay --browser, or a
# cluster replay with --browser). Prints a plain-text report on stdout.
#
#   find-playwright.sh [repo-dir]      # default: the current directory
#
# The runner replaces the author's playwright.config.* with its own, sets
# baseURL from --test-against, runs Chromium only, and in a cluster ships only
# the journeys directory (no node_modules). The findings below are the usual
# places a suite depends on something that is then gone.
#
# Read-only: it never runs a test, installs anything or edits a file.
set -euo pipefail

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

case "${1:-}" in
  -h|--help) usage 0 ;;
esac
ROOT=${1:-.}
[ -d "$ROOT" ] || { echo "not a directory: $ROOT" >&2; exit 2; }
ROOT=$(cd "$ROOT" && pwd)

EXCLUDES=(--exclude-dir=node_modules --exclude-dir=.git --exclude-dir=dist
  --exclude-dir=build --exclude-dir=test-results --exclude-dir=playwright-report
  --exclude-dir=blob-report --exclude-dir=.next --exclude-dir=coverage)
SRC=(--include='*.ts' --include='*.tsx' --include='*.js' --include='*.jsx'
  --include='*.mjs' --include='*.cjs' --include='*.mts' --include='*.cts')

rel() { sed "s#^$ROOT/##"; }
section() { printf '\n== %s\n' "$1"; }
# lines_into <array-name>: read stdin into the array, one element per non-empty
# line. Stands in for mapfile, which the bash 3.2 that macOS ships lacks.
lines_into() {
  local _line
  eval "$1=()"
  while IFS= read -r _line || [ -n "$_line" ]; do
    [ -n "$_line" ] || continue
    eval "$1+=(\"\$_line\")"
  done
}
# hits <label> <regex> <files...>: one line per matching line, capped.
# HITS_EXCLUDE, when set, drops matching lines that also match it.
hits() {
  local label=$1 re=$2; shift 2
  [ $# -gt 0 ] || return 0
  local out
  out=$(grep -nE "$re" "$@" 2>/dev/null | { grep -vE "${HITS_EXCLUDE:-^\$}" || true; } | rel | head -n 15 || true)
  [ -n "$out" ] || return 0
  printf -- '- %s\n' "$label"
  printf '%s\n' "$out" | sed 's/^/    /'
}

section "Tooling"
printf 'node: %s\n' "$(node --version 2>/dev/null || echo 'not found')"
if command -v proxymock >/dev/null; then
  printf 'proxymock: %s\n' "$(proxymock version 2>/dev/null | head -n 1 || echo unknown)"
  if proxymock replay --help 2>/dev/null | grep -q -- '--browser'; then
    echo 'proxymock replay --browser: supported'
  else
    echo 'proxymock replay --browser: NOT supported by this build; upgrade proxymock'
  fi
else
  echo 'proxymock: not found'
fi

section "@playwright/test declared in package.json"
lines_into PKGS < <(grep -rlE '"@playwright/test"' "${EXCLUDES[@]}" --include=package.json "$ROOT" 2>/dev/null || true)
if [ ${#PKGS[@]} -eq 0 ]; then
  echo '(none)'
else
  for p in "${PKGS[@]}"; do
    v=$(grep -oE '"@playwright/test" *: *"[^"]+"' "$p" | sed -E 's/.*: *"([^"]+)"/\1/')
    installed=$(cat "$(dirname "$p")/node_modules/@playwright/test/package.json" 2>/dev/null \
      | grep -oE '"version" *: *"[^"]+"' | head -n 1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
    printf '%s  declared %s  installed %s\n' "$(echo "$p" | rel)" "$v" "${installed:-none}"
  done
fi

section "Playwright configs (ignored by the runner; settings below must move into specs or the test config)"
lines_into CONFIGS < <(find "$ROOT" \( -name node_modules -o -name .git \) -prune -o \
  -type f -name 'playwright*.config.*' -print 2>/dev/null | sort)
if [ ${#CONFIGS[@]} -eq 0 ]; then
  echo '(none)'
else
  for c in "${CONFIGS[@]}"; do
    echo "$c" | rel
    hits 'testDir / testMatch' '^\s*(testDir|testMatch|testIgnore)\s*:' "$c"
    hits 'baseURL (comes from --test-against instead)' 'baseURL\s*:' "$c"
    hits 'globalSetup / globalTeardown / setup projects (not run; sign-in moves to storage state)' \
      'globalSetup|globalTeardown|dependencies\s*:|teardown\s*:' "$c"
    hits 'webServer (not started; start the app yourself)' 'webServer' "$c"
    hits 'storageState / httpCredentials / extraHTTPHeaders (move to the test config or test.use)' \
      'storageState|httpCredentials|extraHTTPHeaders' "$c"
    hits 'use options to carry into specs with test.use' \
      'testIdAttribute|viewport|locale|timezoneId|colorScheme|permissions|geolocation|userAgent|isMobile|deviceScaleFactor|devices\[' "$c"
    hits 'non-Chromium projects (the runner is Chromium only)' "firefox|webkit|Desktop Safari|Desktop Firefox|channel\s*:" "$c"
    hits 'retries / timeouts (runner: retries 0, journeyTimeout from the test config)' \
      '^\s*(retries|timeout|expect)\s*:' "$c"
  done
fi

section "Spec files that import @playwright/test, by directory"
lines_into SPECS < <(grep -rlE "from ['\"]@playwright/test['\"]|require\(['\"]@playwright/test['\"]\)" \
  "${EXCLUDES[@]}" "${SRC[@]}" "$ROOT" 2>/dev/null | grep -E '\.(spec|test|setup)\.[cm]?[jt]sx?$' | sort || true)
if [ ${#SPECS[@]} -eq 0 ]; then
  echo '(none: build journeys from the app instead; see the skill)'
else
  printf '%s\n' "${SPECS[@]}" | xargs -n1 dirname | sort | uniq -c | rel | sed "s#  *$ROOT/#  #"
  printf 'total: %d\n' "${#SPECS[@]}"

  section "Portability findings in specs and their helpers"
  lines_into HELPERS < <(printf '%s\n' "${SPECS[@]}" | xargs -n1 dirname | sort -u \
    | xargs -I{} find {} -type f \( -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) \
      -not -path '*/node_modules/*' 2>/dev/null | sort -u)
  FILES=(${HELPERS[@]+"${HELPERS[@]}"})
  hits 'absolute URLs in navigation (use paths so --test-against applies)' \
    "(goto|toHaveURL|waitForURL)\(\s*['\"\`]https?://" "${FILES[@]}"
  hits 'process.env reads (nothing sets them in a cluster run)' 'process\.env' "${FILES[@]}"
  HITS_EXCLUDE="@playwright/test|['\"]node:" hits \
    'package imports other than @playwright/test (no node_modules in a cluster run)' \
    "^\s*import .* from ['\"][^./'\"][^'\"]*['\"]|require\(['\"][^./'\"]" "${FILES[@]}"
  hits 'imports that leave the directory (check they stay inside the journeys dir)' \
    "from ['\"]\.\./|require\(['\"]\.\./" "${FILES[@]}"
  hits 'file uploads (only .json .csv .txt and source files ship to a cluster)' 'setInputFiles' "${FILES[@]}"
  hits 'per-file browser or auth overrides' 'test\.use\(\s*\{[^}]*(storageState|browserName|channel)' "${FILES[@]}"
  hits 'serial or ordered tests (the runner is fullyParallel with no retries)' \
    "describe\.serial|mode:\s*['\"]serial['\"]" "${FILES[@]}"
  hits 'fixed waits (flaky under load and in perf runs)' 'waitForTimeout\(' "${FILES[@]}"
  hits 'test.only (the runner sets forbidOnly)' '\.only\(' "${FILES[@]}"
fi

section "Other browser test frameworks (port selected flows only if asked)"
find "$ROOT" \( -name node_modules -o -name .git \) -prune -o -type f \
  \( -name 'cypress.config.*' -o -name 'cypress.json' -o -name 'wdio.conf.*' -o -name 'nightwatch.conf.*' \
     -o -name 'testcafe*.json' -o -name 'puppeteer*.config.*' \) -print 2>/dev/null | rel | head -n 10
true

---
name: browser-journey-tests
description: Find a web app's existing Playwright tests, or build a basic set from the app's routes, port them to Speedscale's browser runner, and turn the same journeys into both a regression gate (every journey passes, against mocks or the real backend) and a performance gate (web-vitals budgets, plus an API load test from a backend recording made while the journeys run). Runs them on this machine against a local dev server, against a hosted test environment such as staging, or inside a Kubernetes cluster. Use when users ask to regression-test or performance-test a frontend, dashboard or web UI, to reuse their Playwright suite with Speedscale or proxymock, to write browser tests for an app that has none, or to run browser journeys in staging, a cluster pod, or locally.
argument-hint: <repo-dir> [--target <frontend-url>]... [--build | --port] [--regression | --performance | --both]
---

# Browser Journey Tests

One directory of plain `@playwright/test` specs ("journeys") feeds two gates:

- **Regression:** every journey passes, gated on `browserJourneyPassPct`, with
  the frontend's API calls answered from a recording (hermetic) or sent to the
  real backend (observed).
- **Performance:** web-vitals budgets on the same journeys (Tier A), and an API
  load test from the backend traffic the journeys generate (Tier B).

Speedscale's browser runner executes and scores them. Do not write a runner,
a wrapper around Playwright, or a custom reporter. Terms (HIT/MISS, verdict,
exit code) are defined in
[quality-loop](../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill).

**Requires** a proxymock build whose `proxymock replay --help` lists
`--browser`, plus node and `@playwright/test` with Chromium installed
(`npx playwright install chromium`) in or above the journeys directory.
`scripts/find-playwright.sh` checks the first two.

## 0. Ask once, then do not ask again

Unless the user already said:

1. **Targets.** Which of these the journeys must run against, with URLs: a
   local dev server, a hosted test environment (staging, QA, preview), a
   cluster (the journeys run in the generator pod). Production only if the user
   names it, and then read-only journeys only.
2. **Writes.** Which targets are safe for journeys that create, edit or delete.
   Default: none.
3. **Identity.** Which test account the journeys sign in as, and where its
   credentials live. Never use the user's own account or browser cookies.

## 1. Find what exists

```bash
scripts/find-playwright.sh <repo-dir>
```

It lists `@playwright/test` versions, configs, spec directories and the
portability findings: settings in `playwright.config.*` the runner ignores,
absolute URLs, `process.env`, package and out-of-directory imports, uploads,
serial tests, fixed waits, `test.only`. Read the specs it lists and the app's
router and navigation before deciding.

- **Specs exist:** port the ones that cover real user flows (step 2a). Leave
  measurement or fully stubbed specs (every API call answered by `page.route`)
  where they are; they test something else.
- **None exist,** or the user asked for a fresh set: build them (step 2b).
- **Cypress, WebdriverIO or other frameworks:** port only the flows the user
  picks. Do not convert a whole suite unasked.

## 2. Write the journeys directory

Put journeys in a new directory with `read-only/` and, if writes were allowed,
`writes/` (for example `e2e/journeys/read-only/`), following the repo's layout.
Copy and adapt existing specs rather than editing the team's suite in place,
unless that suite already meets the checklist. Read
[references/porting-checklist.md](references/porting-checklist.md) before
writing a line: it covers what the runner sets, what ships to a cluster,
sign-in, enforcing read-only, and selectors.

**2a. Port.** Apply the checklist file by file. Move each `use` option the
config carried into `test.use`, each env var into a constant or the storage
state, and each setup project into storage state.

**2b. Build.** Derive journeys from the app, not from imagination:

- One journey per user-visible capability: each top-level route renders its
  main content; list to detail; search or filter changes the result; key forms
  validate. Start with 5 to 10, not 50.
- The first journey is the **auth canary** (it asserts the expected test
  identity), so a broken sign-in shows as one red line.
- Wrap meaningful actions in `test.step('open order', ...)`. Steps appear in
  the report, and each captured request is credited to its step.
- Assert an outcome the user would see (a row, a heading, a total), never only
  that navigation finished.
- A person can record a journey with `proxymock record --browser <url>`
  (Playwright codegen in a window; close it to stop). An agent cannot click
  through codegen, so write the spec from the code instead.

**Stability check.** Run the directory three times in a row (step 4's command
works, or plain `npx playwright test <dir>` with a throwaway config that sets
`baseURL`). A journey that fails even once is fixed or removed before it joins
a gate. Retries are off in the runner, so flake is failure.

## 3. Make a recording

`proxymock replay` needs a recording in `--in` even in browser mode, and the
recording is also the mock set for hermetic runs. Pick one:

- **Headless, agent-run:** start `proxymock record --out proxymock/recorded-<name>`
  in the background (outbound proxy on port 4140), run the journeys once with
  plain Playwright through it (a throwaway config with
  `use: { baseURL, proxy: { server: 'http://localhost:4140' }, ignoreHTTPSErrors: true }`),
  then stop the recording. Keep only the API hosts' directories: Chromium sends
  the frontend's own page loads, and its background update checks, through
  the proxy too.
- **A person at the keyboard:** `proxymock record --browser <frontend-url>`;
  it also writes a starter spec under `<out>/journeys/`.
- **A DevTools HAR:** `proxymock import har session.har --mocks-only --out proxymock/recorded-<name>`.

Then summarize it ([proxymock-summarize-recording](../proxymock-summarize-recording/SKILL.md))
and confirm the API hosts the journeys call are there.

**APIs on the frontend's hostname cannot be mocked from the browser.** The
runner always bypasses the proxy for the base URL's hostname, on every port, so
mocks never see calls to that hostname: an API on the frontend's own origin (a
dev-server proxy, or `/api` served by the same host) and an API on another port
of it (frontend on `localhost:5173`, API on `localhost:8080`) both reach the real
backend, and the run reports no misses. Run that app in observed mode (real
backend), or for hermetic runs point the API base URL at a different hostname
(for example `127.0.0.1:8080` with the frontend on `localhost:5173`).

## 4. Regression gate

```bash
proxymock test-config new <name>-regression --from standard
jq '.rules = [{"metricName":"browserJourneyPassPct","type":"TOO_LOW","value":100,"action":"ALERT"}]' \
  proxymock/testconfigs/<name>-regression.json > proxymock/testconfigs/<name>-regression.json.tmp \
  && mv proxymock/testconfigs/<name>-regression.json.tmp proxymock/testconfigs/<name>-regression.json
proxymock test-config compile <name>-regression >/dev/null
```

Put sign-in (`generator.browser.storageState`, `generator.browser.tokens`) and
`generator.browser.journeyTimeout` in this config, never on a command line.
A config holding a resolved secret is not committed; one holding only
`${{secret:...}}` references can be.

**Hermetic** (API answered from the recording):

```bash
proxymock mock --in proxymock/recorded-<name>          # background; forward proxy on 4140
proxymock replay --in proxymock/recorded-<name> --browser <journeys>/read-only \
  --test-against <frontend-url> --test-config <name>-regression \
  --browser-proxy http://localhost:4140 --browser-ignore-https-errors \
  --browser-block '<analytics-glob>'
```

**Observed** (real backend, answers compared with the recording): the same
`replay`, with the mock server started as
`proxymock mock --in proxymock/recorded-<name> --observe-real-apis`. Every call
then goes to the real API, and one that answers differently from the recording
is named on the step that made it. Dropping `--browser-proxy` also reaches the
real API, but nothing is compared.

Read the output: `✓`/`✗` per journey with file and line, `not in the recording:`
(a mock miss: hand off to [improve-mock-match-rate](../improve-mock-match-rate/SKILL.md)),
`answered differently from the recording:`, the pass count, p95 vitals, and the
path to traces of failed journeys. `browser-journey-results.json` in the out
directory has the same data, and `proxymock web` shows it.

Then read the `TEST CONFIG GOALS` block. Each browser goal must say `PASS` or
`FAIL`. `NOT EVALUATED ... no source for the metric` means this proxymock
build does not evaluate browser goals locally (cluster and cloud replays always
do). A failed journey still fails the run there, through the implicit
`failedVUsers <= 0` goal, but a web-vitals budget never can. Upgrade proxymock
before relying on step 5 locally, and say so in the result.

**Prove the gate can fail.** Add a throwaway journey that cannot pass
(`await expect(page).toHaveTitle('not-this-app')`), run, confirm exit code 1
and the missed goal, then delete it. Do the same once with the auth canary by
running without storage state: it must fail on its own line.

## 5. Performance gate

Read [references/performance.md](references/performance.md). In short:

- **Tier A (always):** baseline the regression journeys, set p95 budgets on
  `browserLcpP95`, `browserFcpP95`, `browserTtfbP95`, `browserClsP95` with
  `browserJourneyPassPct TOO_LOW 100` alongside, in `<name>-perf`. Measure a
  production build or hosted environment for absolute numbers; a dev server is
  only good for comparing builds. Prove one budget can fail.
- **Tier B (when the backend can be recorded):** record the backend's inbound
  traffic while the journeys run, then load it with
  [proxymock-load-test](../proxymock-load-test/SKILL.md) or, for a cluster
  workload, [run-snapshot-replay](../run-snapshot-replay/SKILL.md) in load mode.
  The browser run's own captured traffic is outbound and cannot be the load
  workload. If the backend cannot be recorded, Tier B is **untested**, said so.

## 6. Run it on each target

| Target | Command |
| --- | --- |
| Local dev server | step 4's command, `--test-against http://localhost:<port>` |
| Hosted test environment | the same, `--test-against https://<staging-host>`, read-only journeys unless writes were allowed |
| In a cluster (generator pod) | `proxymock cluster replay start --in proxymock/recorded-<name> --browser <journeys>/read-only --target <frontend-url> --test-config <name>-regression --wait` (add `--no-mocks` for the real backend) |
| Scheduled in Speedscale cloud | `proxymock cloud push snapshot --in proxymock/recorded-<name> --browser <journeys>/read-only`, then schedule a replay of that snapshot with the test config |

For the cluster and cloud, hand the mechanics (context, namespace, snapshot
source, waiting, reading the report) to
[run-snapshot-replay](../run-snapshot-replay/SKILL.md). Cluster specifics:

- The URL must be reachable **from the pod**: a public hosted environment or an
  in-cluster service URL, never `localhost`.
- Only the journeys directory ships, with no `node_modules`. The checklist's
  import rule is what makes it run there.
- Secrets referenced as `${{secret:<name>/<key>}}` must exist as Kubernetes
  secrets in the replay's namespace.
- Failed journeys' traces and screenshots come back with the report, or, for a
  cloud-free run, under `./browser-artifacts/<report-id>/`.
- `--snapshot-source cloud` also compares the real API's answers with the
  recording; a cloud-free run does not.

Wire each target as one script or package task (for example
`journeys:local`, `journeys:staging`, `journeys:cluster`) that runs the exact
command above, so the gate reruns with no agent. A saved gate is done only
after its entry point has run once, unattended, and passed.

## Result

End with exactly this block:

```
### Result
- **Ran:** what ran, against what
- **Outcome:** pass, fail, or the headline number
- **Numbers:** the 2 to 4 metrics that matter for this skill
- **Artifacts:** paths the run wrote
- **Next:** one suggested next step, naming the skill or giving a prompt
```

For this skill: **Ran** is the journeys directory (ported or built, and how
many journeys), the recording, the mode (hermetic or observed) and each target
run. **Outcome** is the regression gate's pass/fail per target and the
performance gate's verdict, naming Tier B as untested when it did not run.
**Numbers** are journeys passed of total, p95 LCP and TTFB, and Tier B's p95
latency and rps when it ran. **Artifacts** are the journeys directory, the
recording, both test configs, `browser-journey-results.json`, and the entry
points created. **Next** is the next target to wire, `improve-mock-match-rate`
for mock misses, or `proxymock-perf-container` to judge a Tier B number.

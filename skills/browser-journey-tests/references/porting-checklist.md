# Porting Playwright specs to the browser runner

Speedscale's browser runner (`proxymock replay --browser`, and the generator in
a cluster) runs plain `@playwright/test` specs, but under **its own** generated
config. Whatever the author's `playwright.config.*` did is gone. Port each
setting deliberately; do not assume it carries over.

## What the runner sets

| Runner behavior | What the journeys must do |
| --- | --- |
| `use.baseURL` = `--test-against` / `--target` (or `generator.browser.baseUrl`) | Navigate with paths: `page.goto('/orders')`, `toHaveURL(/\/orders/)`. An absolute URL to the frontend pins the journey to one environment. |
| Chromium only, headless | Drop Firefox/WebKit/mobile-Safari variants; they cannot run here. |
| `fullyParallel: true`, `retries: 0`, `forbidOnly: true` | Every test independent of order and of other tests' data. No `test.only`. A test that only passes on retry is flaky: fix or drop it. `test.describe.configure({ mode: 'serial' })` still works inside one file, for a genuinely ordered flow. |
| `trace: retain-on-failure`, `screenshot: only-on-failure` | Nothing to do; failed journeys keep a trace (open it with `npx playwright show-trace`). |
| `serviceWorkers: 'block'` | An app that needs its service worker (offline mode, push) cannot be tested on that path. |
| `journeyTimeout` from the test config, else Playwright's default (30s) | Set `generator.browser.journeyTimeout` (e.g. `"120s"`) for slow flows rather than `test.setTimeout` everywhere. |
| No `webServer`, `globalSetup`, `globalTeardown`, or setup projects | Start the app yourself before the run. Sign-in moves to storage state (below). Per-test seed data moves into the test (`test.beforeEach` through the UI or `request`), cleaned up in `afterEach`. |
| No env vars in a cluster | No `process.env` reads for anything the journey needs. Constants live in a small helper file inside the journeys directory; secrets live in the storage state. |

`use` options the config carried move to the spec file with `test.use`:
`viewport`, `locale`, `timezoneId`, `colorScheme`, `testIdAttribute`,
`extraHTTPHeaders`, `permissions`, `geolocation`. For example:

```ts
import { test, expect } from '@playwright/test';
test.use({ viewport: { width: 1440, height: 900 }, testIdAttribute: 'data-test' });
```

## What ships to a cluster

A cluster or cloud run packs the journeys directory into the snapshot. Only
`.ts .tsx .js .jsx .mjs .cjs .mts .cts .json .csv .txt` files are packed (5 MB
total); `node_modules`, `.git`, `test-results`, reports and `playwright.config.*`
are skipped. The generator image supplies `@playwright/test` (pinned to the
image's version, 1.62.x at the time of writing).

- **Imports:** only `@playwright/test` and relative files *inside* the journeys
  directory. A helper that imports the app's source (`../src/...`), generated
  API clients, or any other npm package works locally but fails in a cluster.
  Copy the few types or constants you need into a helper in the journeys
  directory instead.
- **Fixtures:** test data as `.json`, `.csv` or `.txt` beside the spec.
  `setInputFiles` with an image or PDF does not ship; generate the file in the
  test (`{ name, mimeType, buffer }`) or keep that journey local-only.
- **Version:** use only APIs available in the image's Playwright version.
  Locally, the journeys' nearest `node_modules/@playwright/test` wins, and its
  Chromium must be installed (`npx playwright install chromium`).

## Sign-in

The runner loads `generator.browser.storageState` into every journey's
context. Values may contain `${{secret:<name>/<key>}}` (resolved from secrets
the operator mounts) or `${{token:<name>}}` (minted once before the run by a
`token_fetch` or `oauth_client_credentials` transform in
`generator.browser.tokens`). Check the exact field names with
`proxymock test-config meta`.

- Find how the app keeps its session: a cookie (name, path, `Secure`,
  `HttpOnly`, `SameSite`), or a token in `localStorage`. Read the login code
  and the server's session handler; do not guess.
- Cookies need a `domain`. A `__Host-` cookie must not have one, so it may be
  rejected. If so, seed the token into `localStorage` and have a small helper
  in the journeys directory trade it for the session the way the app does
  (for example `page.request.post('/session', { headers: { Authorization } })`).
- Tokens are minted once and never refreshed. Keep the whole run shorter than
  the token lifetime.
- The session appears in captured `Cookie`/`Authorization` headers and in a
  failed journey's trace. Use a dedicated test identity with least privilege,
  and DLP for cloud runs. Never put a real user's credentials in a journey, a
  test config you commit, or a command line.
- Make the first journey an **auth canary**: it asserts the signed-in user (or
  tenant) is the expected test identity. Every other journey failing on a
  login page is then explained by one red line, and a wrong environment is
  caught before anything else runs.

## Read-only vs writing journeys

Keep two directories and pass only one to `--browser`:

- `read-only/`: navigates, filters, opens details, and asserts. Safe against
  shared environments. Enforce it rather than trusting it: a helper that
  `page.route`s the app's write endpoints (or everything that is not a GET or
  a known read RPC) to abort and fail the test.
- `writes/`: creates, edits, deletes. Each test creates what it changes with a
  unique name and deletes it in `afterEach`. Run only against environments the
  user said are safe for writes, never production.

## Selectors

Prefer `getByRole`, `getByLabel`, and `getByText` on user-visible text, then
the app's existing `data-testid`s. Do not invent CSS chains against generated
class names. If a needed element has no accessible name or test id, add one
in the app in a separate small change, following the app's existing naming.
Replace `waitForTimeout` with a web-first assertion
(`await expect(locator).toBeVisible()`); fixed waits make a performance run
measure the sleep.

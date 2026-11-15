# Performance from browser journeys

The browser runner runs each journey **once** per replay; it has no virtual
users and no duration. Performance therefore has two tiers, and a result
names which tiers ran.

## Tier A: what users feel (always available)

Each journey reports web vitals, and the run reports aggregates that a test
config's `rules` can gate:

| Metric | Meaning |
| --- | --- |
| `browserJourneyPassPct` | Percent of journeys that passed. Gate at `TOO_LOW 100` in every perf config: a fast failure is not a pass. |
| `browserLcpP50` / `browserLcpP95` / `browserLcpMax` | Largest Contentful Paint, ms |
| `browserFcpP50` / `browserFcpP95` / `browserFcpMax` | First Contentful Paint, ms |
| `browserTtfbP50` / `browserTtfbP95` / `browserTtfbMax` | Time to First Byte, ms |
| `browserClsP50` / `browserClsP95` / `browserClsMax` | Cumulative Layout Shift (unitless) |

Steps:

1. **Measure where it means something.** A dev server (Vite, webpack-dev-server,
   `next dev`) serves unbundled, unminified code; its vitals are only useful to
   compare two builds on the same machine. For absolute budgets, run against a
   production build (`vite preview`, `next start`, the built container) or a
   hosted test environment. Say which in the result.
2. **Get samples.** One run is one sample per journey. For a stable p95, either
   replay the run 3 to 5 times and compare, or keep a `perf/` journeys
   directory whose specs register the journey several times:

   ```ts
   for (const i of [1, 2, 3, 4, 5]) {
     test(`open orders #${i}`, async ({ page }) => { /* the same journey */ });
   }
   ```

   `--browser-workers N` runs N journeys at once, which adds concurrency
   (useful for "does it degrade with 4 users at once"), but never more than
   the number of journeys. Browser concurrency is not a throughput test; that
   is Tier B.
3. **Baseline, then set budgets.** Run on the current build with the
   regression config, read the p95s from the terminal summary
   (`Web vitals (p95 across journeys): ...`) or `browser-journey-results.json`.
   Set each budget above the worst of the baseline runs, with headroom for
   run-to-run jitter (about 20%, more when the numbers are tens of
   milliseconds and a few milliseconds of noise is a large share), never looser
   than a target the user gave. A budget only a regression can cross is the
   point: an 800 ms API slowdown that leaves every journey passing should
   still trip it. If the user has no target, Core Web Vitals
   "good" thresholds are a sensible ceiling: LCP 2500 ms, FCP 1800 ms,
   TTFB 800 ms, CLS 0.1.
4. **Write the config.**

   ```bash
   proxymock test-config new <name>-perf --from <name>-regression
   jq '.rules = [
     {"metricName":"browserJourneyPassPct","type":"TOO_LOW","value":100,"action":"ALERT"},
     {"metricName":"browserLcpP95","type":"TOO_HIGH","value":2500,"action":"ALERT"},
     {"metricName":"browserFcpP95","type":"TOO_HIGH","value":1800,"action":"ALERT"},
     {"metricName":"browserTtfbP95","type":"TOO_HIGH","value":800,"action":"ALERT"},
     {"metricName":"browserClsP95","type":"TOO_HIGH","value":0.1,"action":"ALERT"}
   ]' proxymock/testconfigs/<name>-perf.json > proxymock/testconfigs/<name>-perf.json.tmp \
     && mv proxymock/testconfigs/<name>-perf.json.tmp proxymock/testconfigs/<name>-perf.json
   proxymock test-config compile <name>-perf >/dev/null
   ```

5. **Prove a budget can fail.** Run once with one budget set impossibly low
   (e.g. `browserLcpP95 TOO_HIGH 1`) and confirm a nonzero exit and the missed
   goal in the output, then restore it. A budget that cannot fail is not a gate.
   If the goal reads `NOT EVALUATED` instead, the local proxymock build does
   not evaluate browser goals: upgrade it, or run the perf gate in a cluster.

Third-party scripts (analytics, chat, error reporting, A/B tools) dominate and
randomize vitals. Block them with `--browser-block '<glob>'` (repeatable) in
both the baseline and the gated run, or the comparison is noise.

## Tier B: what the API tier sustains (needs a backend recording)

The requests a browser run captures are the **browser's outbound** calls. A
load replay sends only **inbound** requests, so the browser run's own output
is not a load workload. To load-test the API behind the frontend, record the
backend's inbound traffic **while the journeys drive the frontend**:

- **Backend runs on this machine:** start it under `proxymock record`
  (see [record-traffic](../../record-traffic/SKILL.md)) and point the
  frontend's API base URL at the recorded app's inbound port (4143 by default),
  then run the regression journeys once. Stop the recording. That recording's
  inbound pairs are real user-shaped API traffic; hand it to
  [proxymock-load-test](../../proxymock-load-test/SKILL.md), and to
  [proxymock-perf-container](../../proxymock-perf-container/SKILL.md) to judge
  the number.
- **Backend is a cluster workload with the Speedscale operator:** capture it
  in the cluster while the journeys run (record-traffic's cluster mode), then
  run the snapshot in **load** mode with
  [run-snapshot-replay](../../run-snapshot-replay/SKILL.md).
- **Neither** (a third-party or production-only API you cannot record): report
  Tier B as **untested**. Do not load a shared or production API from a
  laptop to stand in for it.

Report both tiers in the result: Tier A's p95 vitals and pass percent, Tier B's
p95/p99 latency, rps and failed count, or "untested" with the reason.

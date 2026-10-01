# Perf container: reading the numbers

Read on demand from `SKILL.md`.

## What comparisons are valid

- **Within one run: yes.** Repeat samples at a fixed VU level in the same
  session spread about **1%**. Take several, let the worst one gate, and that
  comparison is sound.
- **Across runs on a contended host: no.** The same VU level against the same
  build has measured **9,067 rps and 11,597 rps** on separate runs, **27%
  apart**, while within-run spread stayed near 1%. No margin rescues that: 30%
  hides real regressions, 10% fails runs that changed nothing. Re-establish the
  baseline on the host you gate on, in the same session.
- **Prefer efficiency for anything that travels.** A raw rps ceiling is a fact
  about this host. **rps per app-core** survives a move to a sized container: an
  app that holds a steady rps per core across VU levels needs roughly
  `budget / rps-per-core` cores to serve a budget.

## What the latency numbers mean

- **p99 of a few ms with dependencies mocked is the service's own overhead.** It
  excludes real dependency round trips entirely, so it is the floor your service
  adds, not a production latency.
- Percentiles are integer milliseconds, so sub-5 ms p50/p95 deltas are rounding.
- **`failed` above 0 at some level:** transport errors or timeouts under load.
  Check the app log at that level before trusting the rps.

## Finding the knee by hand

Walk a ladder in ascending order (`1,4,16,50`) and look for the first level
whose rps gain over the previous level falls under ~10%. That is the plateau;
the knee is the level before it, and sustainable throughput is reported there,
never at the max VU level, which typically buys a little rps for a lot of p99.
Exclude harness-bound levels from the search: a plateau made of harness-bound
rungs is a measurement of the generator.

## The harness-bound rules by hand (older builds)

Newer proxymock prints the verdict itself. On older builds, treat a level as
harness-bound when **host idle is under about 20%**, or **(generator + mock) CPU
is over about 2x the app's CPU**. The host-idle rule reads the whole host, so
unrelated background load trips it, which is correct: perf numbers from a busy
host are not app numbers. CI runners need a quiet or pinned host.

## Counting the mock as harness

The mock server is test infrastructure and must be counted. Example at VU 4:
app 128%, generator 248%, mock 229%, host idle 26%. Generator-only, the ratio is
248/128 = 1.9x, under the threshold, and the level reads clean, blessing the
throughput as an app number while test infrastructure burned 3.7x the app's CPU.
Counting the mock puts harness at 475% against 2x app 256%, and the level is
correctly refused.

## Measuring CPU by hand

Measure CPU from cumulative cputime deltas between samples, not from `ps`'s
`%cpu` column: that column is a decaying lifetime average and under-reports a
long-lived app under a short burst (an app serving 4k rps read 1%).

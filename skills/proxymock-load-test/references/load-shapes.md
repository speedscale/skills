# Load test: high-throughput mode and load shapes

Read on demand from `SKILL.md`. `proxymock-load-test.sh` is the bundled script in this skill's `scripts/`.

## High-throughput mode (--performance)

For pure-load runs where match rate does not matter, pass `--performance`.
The script's own flag name is unchanged, but as of proxymock v2.5.805 it
forwards `proxymock replay --load-test`: the flag was renamed, and the old
`--performance` still works but prints `Flag --performance has been
deprecated, use --load-test instead` on every run. The mode skips
per-response match scoring and granular response collection on the
generator. Combined with starting the mock side as `proxymock mock --no-out
...` (skip writing every observed pair to disk, the biggest mock-side CPU
cost), profiling on an 18-core M-series host measured +67% throughput (13.7k
to 22.9k rps) and p99 down from 52 to 28 ms on identical hardware versus
default flags — that is high-throughput mode plus `mock --no-out` against a
default replay writing every pair to disk, so it is a both-sides figure, not
the effect of the replay flag alone.

The caveat: `--load-test` omits `requests.result-match-pct` from the results
entirely, because responses are not scored. The summary reports `matchPct`
as null with an explanatory note instead of a number, and the script refuses
a `--fail-if` on `requests.result-match-pct` when `--performance` is set. It
is opt-in, not the default, because the default mode's match data is what
several consumers gate on.
`--load-test` also writes no replay output directory at all — no RRPair
files and no `replay-verdict.json` — so nothing downstream can read per-pair
results from a high-throughput run.

## Load shape: sessions and ramps

`--vus` is the default shape: every virtual user loops the whole traffic set
as fast as it can. Two alternatives cover shapes it cannot express:

- `--sessions N` replays N recorded **sessions** concurrently instead. Each
  slot takes one recorded actor's requests and replays them in order,
  preserving the recorded think-time, so the app sees a realistic distinct
  actor per slot rather than N copies of the full set at full tilt. Expect
  far lower rps than `--vus` at the same N — think-time is the point.
  Combinable with `--for` / `--times`.
- `--stage vus=N,for=D,ramp=D` describes one leg of a ramp and is repeatable;
  legs run in order. `ramp` sits *inside* `for` (minimum 5s), not added to
  it, and `sessions=N` may be used in place of `vus=N`. A stage carries its
  own target and duration, so `--stage` cannot be combined with `--vus`,
  `--sessions`, `--for` or `--times`; the script rejects the combination up
  front rather than letting the replay fail after load is already flowing.

```bash
# 20 recorded actors, each replaying its own journey at recorded think-time
proxymock-load-test.sh \
  --in ./proxymock/recorded-<name> --test-against http://localhost:8080 \
  --sessions 20 --for 2m

# warm up at 5 VUs, then ramp to 50 over a minute and hold
proxymock-load-test.sh \
  --in ./proxymock/recorded-<name> --test-against http://localhost:8080 \
  --stage vus=5,for=30s --stage vus=50,for=2m,ramp=1m
```

The summary shape is identical for all three, so `--fail-if` gates and the
`summary.json` contract are unchanged.

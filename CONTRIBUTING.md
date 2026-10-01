# Maintaining the quality-loop skills

Normal skill use runs against the user's app and recordings. The `prove-*.sh` scripts are maintainer checks: they use a separate mock-lab checkout containing known recordings and deliberately seeded failures. Do not run them as part of a user's regression, load, contract, or analysis task.

## Run the proofs

Use the matching mock-lab layout revision with its root `proxymock/` workspace and `shared/` tools. Run from this skills repository's root, with an activated proxymock CLI on PATH. Go is needed for the load and replay-tuning proofs; the scripts report their other required tools.

```bash
export MOCK_LAB_DIR="/absolute/path/to/mock-lab"
bash skills/quality-loop/scripts/prove-quality-loop.sh
bash skills/proxymock-compare-results/scripts/prove-proxymock-compare-results.sh
bash skills/proxymock-summarize-recording/scripts/prove-proxymock-summarize-recording.sh
bash skills/proxymock-load-test/scripts/prove-proxymock-load-test.sh
bash skills/proxymock-replay-tuning/scripts/prove-proxymock-replay-tuning.sh
```

`MOCK_LAB_DIR` is required and is resolved to the checkout's physical path. The proofs do not clone repositories, install skills, or infer a fixture checkout from the skill installation location.

| Proof | Checks |
| --- | --- |
| quality-loop | Doctor and usage exit codes, regression status/body gates, incident-fix inversion, contract violations, chaos behavior, and load gates |
| compare-results | Seeded report regressions and an unchanged baseline comparison |
| summarize-recording | Hosts, endpoints, status mix, non-HTTP pair counts, and report-digest inclusion |
| load-test | The Go app under a recorded downstream mock, real throughput, zero failed requests, and latency percentiles |
| replay-tuning | The Go app against the local reference API, stale mock misses, and an improved tuned hit rate |

One quality-loop proof covers the native regression, verify-fix, contract, chaos, and performance skills. The other proofs cover their bundled analysis helpers. A proof failure is a maintenance finding; it is not a verdict on the user's application.

For current ownership and release mirroring, see the repository README's maintenance section.

# Bootstrap a first regression test with no recording

Use this when a service, or a new endpoint on it, has never been recorded and the user wants a regression test for it. The deliverable is the same as the "own service" flow: a recording that holds the tests and the mocks, a tuned test config, a committed baseline, and a gate script. Only the source of the first requests differs.

**The one rule:** every source below is a driver, never the baseline. Replay or run its requests at the app while `proxymock record` wraps it. The recording then holds the app's real responses and every outbound call it made, which is the only thing the later steps use.

## 0. Inventory and choose

Read the repo as in the "own service" flow: run command, port, outbound hosts, databases, existing tests. Then run the inventory from the service's directory:

```bash
proxymock inventory              # or the MCP inventory tool
proxymock inventory -o json      # for parsing
```

It ranks what the repo offers and marks one `BASE` and the `FILL`:

| Rank | Source | Turn it into candidate requests with |
| --- | --- | --- |
| 0 | An existing recording | Re-run what produced it (driver, suite, script) plus the filler, into the same recording name |
| 1a | A Speedscale cloud capture of a matching service | `pull_remote_recording` |
| 1b | A fresh cluster capture (offered, never auto-chosen) | `record-traffic` cluster mode, after the user confirms context and workload |
| 2 | Postman, HAR, GoReplay, k6, Gatling, an e2e suite, a traffic driver | `import_traffic` for files, or run the suite or driver at the record port |
| 3a | An OpenAPI spec | `generate` with direction `inbound`, then rewrite placeholders |
| 3b | Protobuf for gRPC | One `grpcurl` call per unary RPC, written from the `.proto` |
| 3c | A GraphQL schema | One named operation per root query and mutation field |
| 4 | The code | Requests you write from the routes and handlers |

Take the `BASE` it recommends unless the user said otherwise. Rank 4 is always added on top: the new behavior is in no other source. Tell the user, in the transcript, which sources were found and which were not used and why. Ask only when several cloud services match, or when nothing above rank 4 exists and the run command is unknown. When the inventory finds no spec but notes a repository root, run it once more there.

## 1. Assemble candidates

Put every candidate in `proxymock/candidates-<name>/`. Replay writes a `.replay/` directory beside its input, so candidates never live inside the recording, and `.gitignore` gets `proxymock/candidates-*/`.

- **Rank 0.** Find what produced the recording: the gate script, a README, a traffic driver. Re-running it with the filler gives one consistent recording. Replaying the old recording itself at a stateful app creates new IDs that its later requests do not know, so do that only for a stateless app or with a blueprint that chains the IDs. Existing blueprints and test configs stay; re-run `improve-mock-match-rate` only if the new requests miss.
- **Rank 1a.** Pull into `proxymock/recorded-prod-<date>/` and leave it untouched: it is evidence of real behavior. Review it for credentials and personal data before anything else reads it. Replay it from there: replay only adds its `.replay/` metadata, never edits the pairs. Replay sends the inbound pairs; the recording's outbound pairs stay as evidence of the real dependency responses.
- **Rank 2.** `proxymock import <format> <file> --out proxymock/candidates-<name>`. An e2e suite, k6 script or traffic driver needs no import: step 3 runs it.
- **Rank 3a.** `proxymock generate --direction inbound --include-optional --out proxymock/candidates-<name> <spec>`. Its `PLACEHOLDERS:` block lists the tests whose request still sends `example_value` or `${{param:...}}`. Rewrite each with a value from the code, seed data or the spec's examples, or delete it. Spec-generated requests for error statuses are often valid requests, so they do not reach the error path: write those in the filler instead.
- **Rank 3b and 3c.** Write the requests from the spec, unary RPCs and queries first. Mark streaming RPCs and subscriptions as untested until one has been recorded and replayed.
- **Rank 4, always.** For the new endpoint or the untested routes: the happy path, each validation error, not found, and the auth failure if the service has auth. Five to fifteen requests, as RRPair files in the candidates directory or as a small script in the repo's own language.

## 2. Dependencies

When the real dependencies are reachable from this machine, step 3 records them and nothing else is needed. When one is not, stand up a mock before recording, in this order of preference: the pulled cloud recording; `generate --direction outbound` from the dependency's own spec; a WireMock or HAR import; RRPairs written from its documentation. Report generated and hand-written mocks as fabricated so the user knows to replace them. Never run `generate --direction both` on the service's own spec to mock its dependencies: that mocks the service.

## 3. Realize: drive the candidates through a recording

Start the app under `proxymock record` exactly as `record-traffic` does, with a `--map` per database and `--app-health-endpoint` so readiness is checked on the app's own port. Then send the candidates through the inbound proxy:

```bash
proxymock replay --in proxymock/candidates-<name> --test-against http://localhost:4143 \
  --out proxymock/results/realize-<name>
```

`--in` takes several directories, so a pulled recording and the filler go in one run. Run a suite, driver or `grpcurl` calls at port 4143 instead when that is the source. Never send a readiness probe through 4143: it is recorded. Stop the recording with Ctrl-C (or `record_traffic_stop`). The realize replay's own mismatches are expected and ignored: its expected responses were never real.

## 4. Review before blessing

The recording is about to become a golden file.

- List the inbound pairs by route and status. Every status must be one a candidate meant to produce. A 4xx or 5xx nobody intended means the request or the code is wrong: fix one and re-record. Never bless an accidental error.
- Every outbound host and database the app uses must be in the recording.
- With an OpenAPI spec, run `proxymock validate --spec <spec> --in proxymock/recorded-<name>` on the inbound pairs and save `proxymock coverage --spec <spec> --in proxymock/recorded-<name> --json` beside the results. That coverage file is the number the next session improves.
- Check headers and bodies for secrets and personal data. A pulled production capture is the usual offender.

## 5 and 6. Tune and gate

Continue at step 3 of the "own service" flow: replay once behind `proxymock mock`, hand response differences to `tune-snapshot-replay` and mock misses to `improve-mock-match-rate`, then `proxymock-regression-test` writes the baseline and the gate script. Prove the gate: green on the current code, red with exit 3 on a planted one-word change to the new endpoint, then restore the code.

## Merging new behavior into a cloud recording

Rank 1a is the best base and the most common question. Pull the window into `recorded-prod-<date>/` and keep it immutable. Write the filler for the new endpoint. Realize both in one run (`--in` both directories). Before blessing, compare the old routes' new responses with the pulled originals (`response_diff` or `compare_rrpair_files`): a difference is either volatility for the test config or a regression the branch already introduced, which the user wants to know first. The baseline is the new recording, not the pulled one.

When the service runs in a cluster where the operator is already capturing, the merge can happen there: send the filler through a port-forward, then pull a snapshot of the last few minutes filtered to the workload, and gate it with `run-snapshot-replay` in regression mode.

## What to commit

| Path | Commit |
| --- | --- |
| `proxymock/recorded-<name>/` (tests and mocks, by host) | Yes, under a stable name the gate script names |
| `proxymock/testconfigs/`, `proxymock/blueprints/` | Yes |
| `proxymock/results/<baseline>/` | Yes: CI that regenerates its own baseline from the same code can never fail |
| The gate script | Yes |
| `proxymock/candidates-*/`, other `proxymock/results/*`, `.replay/`, logs, `recorded-prod-*` until reviewed | No |

Commit nothing with credentials or personal data in it; say what was checked.

## Report

Add three lines to the `### Result` block's **Numbers** and **Artifacts**:

- **Entry point:** the base and filler used, and each source found but not used, with the reason.
- **Coverage:** inbound routes or operations recorded against those in the spec or router; the coverage JSON path when a spec exists.
- **Fabricated inputs:** generated or hand-written mocks still in the recording.

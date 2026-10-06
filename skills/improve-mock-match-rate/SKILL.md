---
name: improve-mock-match-rate
description: Tune the mocks behind a Speedscale replay for any technology (HTTP, gRPC, SQL, Redis, Kafka and more). Applies match-rate fixes offline, then re-runs the snapshot against the same workload, compares recorded with mocked traffic, and fixes each discrepancy by its kind. Use when a replay shows NO_MATCH or passthrough mocks or a low mock match rate.
---

# Improve Mock Match Rate

You are tuning the mocks behind a Speedscale replay so the app's OUTBOUND calls are answered from recorded traffic. This works the same for every technology the responder mocks: HTTP, gRPC, Postgres, MySQL, Redis, Kafka, MongoDB and the rest. The mock match rate is the fraction of those calls the mocks answered. Work in two phases:

1. **Offline** (always): analyze, apply and verify fixes from RRPair files in a local workspace, with no replay and no cluster. It ends at a projected match rate.
2. **Confirm** (when the app can be re-run, or the user asks): re-run the snapshot against the same workload, compare what the mocks saw with what was recorded, and fix each discrepancy by its kind. It ends at a measured match rate.

The workspace is either the directory you are already in (from a local record -> mock -> replay) or one pulled from a Speedscale cloud report.

## Without the MCP server

Every tool below has a CLI twin. Run `proxymock <command> --help` for flags.

| MCP tool | CLI |
|---|---|
| mocks with action analyze, similar, accept or undo | `proxymock match-rate <action>` (accept takes `--id` or `--all`) |
| score_replay | `proxymock replay score <run>` (pairs the mock run under proxymock/results/ by itself; `--mock-run <dir>` otherwise) |
| detect_drift | `proxymock drift --source A --source B` |
| mock_server_start + replay_traffic | `proxymock mock --in <recording> --map ... -- <app>` and `proxymock replay --in <recording> --test-against <url>` |
| pull_report | `proxymock cloud pull report <id>` |
| cloud_replay | `proxymock cloud replay` |
| sql_report | MCP only, no CLI |

## Mental model

The responder matches each outbound request's SIGNATURE against the recorded snapshot, after applying the workspace's transform chains (the "tuning blueprint"). The signature is built from the fields that identify a request in its protocol (see the table below). A fix is one transform scoped by a filter, written into that blueprint. Three rates matter, over the same denominator:

- **Report match rate**: the verdicts recorded at replay time. It never changes offline.
- **Projected match rate**: what the NEXT replay would score with the current blueprints. It starts at the report rate and climbs as fixes land. This is the offline phase's objective.
- **Measured match rate**: what a confirming re-run actually scored. This is the confirm phase's objective, and it outranks the projection. Passthrough calls (the responder had no mock for the dependency and forwarded the call) count against it.

## Where the signature lives

| Technology | What usually identifies a request | Where drift usually shows |
|---|---|---|
| HTTP, GraphQL | method, host, path, query params, body fields. Headers are outside the signature | ids in paths, timestamps and nonces in query or body |
| gRPC | service, method, message fields | ids and timestamps in message fields |
| Postgres, MySQL | statement text and message type; bind parameters only for statements keyed with sql_key_params | literals inlined in the statement text. A changed bind never misses: it gets another recording's row (bind drift), or a fallback match on a keyed statement |
| Redis | command and key | keys built from ids, session tokens or dates |
| Kafka and other queues | topic, key, message fields | message keys, ids and timestamps in payloads |
| MongoDB | collection, command, filter document | ids and dates in the filter |

This table is a hint, not a rule set. The mocks analysis and detect_drift name the fields that actually drift, for any protocol, including ones not listed here. Two consequences: a rotating `X-Request-Id` or other header never causes a miss, so do not mask it; and because SQL binds are not matched, a bind value that was never recorded gets the recorded row for that statement, not a miss. So a 100% match rate does not prove SQL correctness: read the analysis's SQL correctness counts (exact, bind drift, fallback) next to it.

## Phase 1: offline loop

1. **LOCATE THE WORKSPACE** — default to the local directory; only reach for the cloud when there is nothing local to tune. Run the mocks tool with action=analyze on the current directory (or a workspace path the user names). A local run is enough, no cloud report needed: with no flags it takes the recording as the mock source and the newest mock run under proxymock/results/ as the request source. If it returns match rates, continue with that result. If it instead errors that no mock/request source was found, the directory holds no recorded-vs-replayed traffic yet: ask the user for a **report id**, pull it with pull_report (the report and its source snapshot land in one workspace), then run mocks action=analyze on that workspace. Never ask for a report id before checking the local directory.
2. **BASELINE** — from that analysis, note the report and projected match rates. If the projected rate is already 100%, SQL correctness shows no bind drift or fallback, and no SQL recommendation is left (reads exact only in recorded order still get one), go to phase 2 to confirm it, or report success if the user wants no re-run.
3. **TRIAGE** — read the recommendation groups and the drift summary. Classify each recommendation with the phase 1 playbook below. For misses listed outside every group, and for any group whose fix isn't obvious, inspect 2–3 of them with mocks action=similar before deciding — the per-field causes are the evidence.
4. **APPLY** — accept high-confidence fixes with mocks action=accept, largest groups first. The response reports the projected-rate movement immediately. action=accept with all=true (CLI `--all`) accepts every pending group, which is fine once triage shows none is a credential or a real discriminator; newer builds merge groups that need the same field fix. Re-run analyze after accepting: the groups can change.
5. **VERIFY** — the projected rate must never drop. If a fix didn't move it (and the playbook doesn't explain why), undo it (mocks action=undo) and reconsider with mocks action=similar.
6. **ITERATE** — repeat 3–5. On a stubborn group, retry with a different transform (the transform parameter). Stop when the projected rate is 100%, no recommendations remain, or two consecutive rounds show no improvement. Cap the loop at ~8 rounds and always leave the blueprint at its best-seen state. Then continue with phase 2, or skip to the report if the app cannot be re-run.

## Phase 2: confirm with a re-run

A projection only counts what the offline analysis can see. A re-run shows what it cannot: passthrough calls, values the replay itself introduced, calls that matched but returned the wrong recording, and fixes (such as smart_replace_recorded) the projection cannot credit. Before the first re-run, tell the user where it will run and get a yes: a cloud workload replay sends traffic to that workload and swaps its dependencies for mocks while it runs. Later re-runs against the same target need no new confirmation.

7. **CHECKPOINT** — before each change, copy the workspace's proxymock/blueprints directory (only that) to proxymock/tuning/checkpoints/<n>/, so any change can be reverted exactly, including ones mocks action=undo does not cover. This is the one checkpoint mechanism for this skill; tune-snapshot-replay keeps its own checkpoints with its own script, and the two do not share a directory.
8. **RE-RUN AGAINST THE SAME WORKLOAD** — default to where the snapshot was recorded.
   - **Cloud**: cloud_replay action=defaults with the snapshot_id (or the report_id) returns the cluster, namespace and workload the dashboard's replay wizard would pre-fill. Start the replay with cloud_replay action=start, in_directories set to the workspace and that same cluster, namespace and workload, and mocking left at its default (every recorded dependency). Push the workspace rather than passing snapshot_id: only a push carries the tuning blueprint. Run it with dry_run=true first and check the plan. Then call cloud_replay action=status with wait=true until it reaches a verdict, and pull the new report with pull_report into its own directory under the workspace's results/ directory (for example proxymock/results/confirm-<n>). Never pull it into the workspace itself: a second snapshot copy there would be pushed with the next re-run.
   - **Cluster** (a workload replayed through the kubeconfig, no Speedscale cloud): proxymock cluster replay start --in <recording> -n <namespace> --workload <workload> --snapshot-source local --wait (the cluster tool, action=replay-start) carries the workspace's tuning blueprint. Its result is the verdict and its goals, without per-call outcomes, so steps 9 and 10 need a local re-run: iterate locally, and use the cluster replay to confirm the final blueprint.
   - **Local**: start mock_server_start with in-directory set to the recording directory (not the whole workspace, which would also ingest earlier results; the workspace's tuning blueprint still applies) and an out-directory under proxymock/results/. Reuse every --map the recording was made with, or a mapped dependency such as Postgres is not mocked and the mock may fail to start while the real one is up. Run the app with its outbound traffic pointed at the mock, the same way it ran when the traffic was recorded. Then run replay_traffic with the inbound traffic against the app, again with an out-directory under proxymock/results/. If the run-snapshot-replay skill is installed, it works out the target and the wiring for either mode.
9. **SCORE** — run score_replay on the new run (the pulled report, or the local replay output), with baseline set to the previous run. Read matchRate (matched, noMatch and passthrough) and accuracy. A gap between the measured rate and the phase 1 projection means the offline analysis missed something; step 10 finds it. If accuracy dropped while the match rate rose, a fix made a mock answer the wrong call: revert it.
10. **COMPARE RECORDED WITH MOCKED** — find what the app sent this run that differs from what was recorded:
    - detect_drift with sources set to the recorded snapshot run and the new run's outbound traffic (the report-<id> run of the pulled report, or the local mocked-* run). It works on any protocol and names each drifting field with a prefilled transform.
    - mocks action=analyze on the workspace with request-source set to the new run, for fresh recommendations and the misses outside every group. Use mocks action=similar on 2–3 misses per group you cannot explain.
    - When the traffic includes SQL, sql_report with baseline-directory set to the recorded run and in-directory set to the new run. New, removed or changed statements mean the app sent a different query, not just a different value.
    - The hosts in matchRate.topMissingHosts that carry passthrough calls were not mocked at all.
11. **CLASSIFY AND FIX ONE CLASS PER RE-RUN** — classify every discrepancy with the phase 2 playbook below. Apply the fixes for the one class that costs the most calls, then go back to step 7. Changing one class per re-run keeps cause and effect readable.
12. **KEEP OR REVERT** — keep the change when the measured match rate rose and accuracy did not drop. Otherwise restore the checkpoint and try the next-best fix for that class. Stop when the measured rate is 100% with no unexplained passthrough, when two re-runs in a row bring no improvement, or after about 5 re-runs, since each one costs real time. Leave the blueprint at its best measured state.

## Phase 1 playbook: recommendations

| Pattern | Signal | Action |
|---|---|---|
| Rotating URL path ids | group scope like `GET /v3/{UUID}/…` | Accept the "URL id segment" rec — a filter-scoped wildcard, safe by construction |
| Trace/correlation headers | drifting `x-request-id`, `traceparent`, `x-b3-*` | Nothing to fix for matching: headers are outside the signature. Mask only if a recommendation ties the header to a body or query field |
| Timestamps / nonces / cache-busters | cause: datetime or random | Mask (constant) — high confidence |
| Pagination cursors, idempotency keys | cause: random on a query/body field | Mask (constant) |
| Lookup keys carrying data | cause: pii on a query/body field | Prefer smart_replace_recorded (maps recorded values) over a blind mask — the value selects WHICH mock answers |
| Auth material | cause: jwt, or an auth/api-key/cookie header | Do NOT auto-accept. Surface to the user: masking can create false matches; token re-signing or a credentials preflight is usually the right fix |
| IDs inside JSON bodies | body-leaf recs, incl. embedded-JSON paths | Accept the body-field rec |
| Opaque low-confidence drift | cause: opaque | Inspect with mocks action=similar and reason: a real discriminator must NOT be masked (it would return the wrong mock) |
| SQL traffic drifting | sql tech in the misses | Check sql_report before masking — literal values in statements often need a different strategy |
| SQL bind drift or fallback | SQL correctness counts; a sql-params rec | A correctness problem even at 100% match rate. Accept the sql_key_params rec for read statements whose ids come from the request, re-run the mock and confirm the counts drop. Ids never recorded then show as fallback matches, not silent wrong rows. Writes that carried new values (new ids, timestamps) are counted apart and expected: leave them |
| SQL reads exact only in recorded order | SQL correctness "only in recorded order" count; a sql-params rec whose cause is sql-order-dependent | The replay sent calls in recorded order, so each read got its own row by luck of order. A reordered or concurrent replay (a load test, --vus) serves them each other's rows. Accept the rec: the analysis then shows it applied, with no re-run needed |

## Phase 2 playbook: discrepancies after a re-run

| Discrepancy | How it shows | Fix |
|---|---|---|
| Noise: a value that changes every run and does not choose the answer | a datetime, uuid, trace id, nonce or random value in a drifting field | Mask it with the prefilled transform, scoped to the group's filter |
| Lookup key: a value that chooses which recording answers | an id, email or account number whose recorded values each have their own response | smart_replace_recorded, which maps each new value to its recorded counterpart. Never a blind mask |
| Carried value: a value the replay itself introduced | the same new value appears in the replayed inbound request and in the outbound call, for example an id or token a generator-side transform rewrote | Map it with smart_replace_recorded, or change the generator-side transform that rewrote it so both sides stay consistent |
| Real discriminator: a difference that changes the correct answer | the app sent a different query, statement, key or topic, not just a different value | Leave the mock alone. Report a possible regression if the app's behavior changed, or recommend re-recording if the snapshot is stale |
| Never recorded | "No similar recorded signatures", or statements, keys or topics the recording never had | No transform fixes it. Re-record covering that code path |
| Passthrough: the dependency was not mocked | passthrough calls in matchRate, hosts in topMissingHosts | Check that the replay mocked that dependency (the mocks list, or where the cloud replay attached its mocks) and that it was captured when recording (for example TLS traffic that was never decrypted). Fix the run setup or re-record, not the blueprint |
| Wrong recording: matched, but the app got a different answer than recorded | the match rate is fine but accuracy dropped on the calls behind it | Several recordings share one signature and are returned in order. Undo the broadest mask that merged them. If the calls really are identical and the answer depends on order, report it rather than masking further |
| Credential | jwt, auth, api-key or cookie fields | Stop and ask the user. Token re-signing or a credentials preflight is usually the fix, not a mask |

## Reading mocks action=similar causes

- **datetime / uuid / trace-id / ip / random** — high-confidence noise; mask.
- **pii (low confidence)** — likely a record-selecting key (email, phone). smart_replace_recorded, not a mask.
- **jwt** — credential; stop and ask the user.
- **opaque (low confidence)** — could be a real discriminator or a correlated id; decide from the values shown, and when in doubt leave it and tell the user.
- **"No similar recorded signatures"** — the endpoint's traffic is absent from the snapshot. No transform fixes that; the snapshot needs to be re-recorded covering that code path.

## Report

Finish with exactly this block, filled in, with these five headings and no others:

```
### Result
- **Ran:** what ran, against what
- **Outcome:** pass, fail, or the headline number
- **Numbers:** the 2 to 4 metrics that matter for this skill
- **Artifacts:** paths the run wrote
- **Next:** one suggested next step, naming the skill or giving a prompt
```

Fill it in like this:
- **Ran:** the workspace, whether phase 2 ran and where (cloud workload or local), and how many rounds and re-runs.
- **Outcome:** the headline, for example "projected 62% to 97%, measured 94%", or fail with the reason.
- **Numbers:** report, projected and measured match rate before and after, and the passthrough count. Say when a rate is a projection only, and add accuracy if it moved.
- **Artifacts:** the blueprint directory (proxymock/blueprints) and the checkpoint paths (proxymock/tuning/checkpoints/<n>/), plus the results/ runs.
- **Next:** one step. A confirming re-run if phase 2 was skipped, re-recording for never-recorded calls, or snapshot action=push to sync the blueprint if the next in-cluster run should use it. Put possible app regressions and what still misses in the Outcome line, separate from the mock fixes.

## Hard rules

- Blueprint-only changes. Never edit_rrpair or delete_rrpairs to force matches.
- Prefer narrowly scoped fixes (the group's filter) over global masks.
- Accepting and undoing are idempotent — experiments are cheap; regressions are not acceptable in the final state.
- smart_replace_recorded fixes cannot be credited by the offline projection (they need recorded data at replay time). "Applied but still projected-miss + smart_replace" is expected — don't churn through alternatives; note it for the replay to confirm.
- A projected 100% is a projection, not a guarantee — say so in the report and recommend a confirming replay if phase 2 did not run.
- Never hide a real regression in the app. A request the app now sends differently is evidence, not noise: do not mask it to raise the match rate.
- Ask before the first re-run, and keep every run's output under proxymock/results/ so it is never read back as recorded traffic.

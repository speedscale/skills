---
name: improve-mock-match-rate
description: Pull a Speedscale replay report and iteratively tune the workspace's mock blueprints until the projected match rate is as high as it can get. Use when a replay shows NO_MATCH mocks or a low mock match rate.
---

# Improve Mock Match Rate

You are tuning a Speedscale replay's OUTBOUND mock match rate: the fraction of the app's outbound requests the responder answered from recorded mocks. The whole loop runs offline from RRPair files in a local workspace — analyze, apply, and verify fixes with no replay and no cluster. The workspace is either the directory you are already in (from a local record -> mock -> replay) or one pulled from a Speedscale cloud report.

## Mental model

The responder matches each outbound request's SIGNATURE (method, host, url, query params, body fields) against the recorded snapshot, after applying the workspace's transform chains (the "tuning blueprint"). A fix is one transform scoped by a filter, written into that blueprint. Two rates matter, over the same denominator:

- **Report match rate** — the verdicts recorded at replay time. It never changes offline.
- **Projected match rate** — what the NEXT replay would score with the current blueprints. Starts at the report rate and climbs as fixes land. This is your objective function.

## The loop

1. **LOCATE THE WORKSPACE** — default to the local directory; only reach for the cloud when there is nothing local to tune. Run the mocks tool with action=analyze on the current directory (or a workspace path the user names). If it returns match rates, this is already a proxymock workspace — continue with that result. If it instead errors that no mock/request source was found, the directory holds no recorded-vs-replayed traffic yet: ask the user for a **report id**, pull it with pull_report (the report and its source snapshot land in one workspace), then run mocks action=analyze on that workspace. Never ask for a report id before checking the local directory.
2. **BASELINE** — from that analysis, note the report and projected match rates. If the projected rate is already 100%, report success and stop.
3. **TRIAGE** — read the recommendation groups and the drift summary. Classify each recommendation with the playbook below. For misses listed outside every group, and for any group whose fix isn't obvious, inspect 2–3 of them with mocks action=similar before deciding — the per-field causes are the evidence.
4. **APPLY** — accept high-confidence fixes with mocks action=accept, largest groups first. The response reports the projected-rate movement immediately; you do not need a separate analyze call to see the effect.
5. **VERIFY** — the projected rate must never drop. If a fix didn't move it (and the playbook doesn't explain why), undo it (mocks action=undo) and reconsider with mocks action=similar.
6. **ITERATE** — repeat 3–5. On a stubborn group, retry with a different transform (the transform parameter). Stop when the projected rate is 100%, no recommendations remain, or two consecutive rounds show no improvement. Cap the loop at ~8 rounds and always leave the blueprint at its best-seen state.
7. **REPORT** — summarize for the user: before → after rates, each accepted fix and the reasoning, what still misses and the likely cause, and next steps (re-run the replay to confirm the projection; snapshot action=push to sync the blueprint to the cloud if they want the next in-cluster run to use it).

## Pattern playbook

| Pattern | Signal | Action |
|---|---|---|
| Rotating URL path ids | group scope like `GET /v3/{UUID}/…` | Accept the "URL id segment" rec — a filter-scoped wildcard, safe by construction |
| Trace/correlation headers | drifting `x-request-id`, `traceparent`, `x-b3-*` | Mask (constant) — high confidence |
| Timestamps / nonces / cache-busters | cause: datetime or random | Mask (constant) — high confidence |
| Pagination cursors, idempotency keys | cause: random on a query/body field | Mask (constant) |
| Lookup keys carrying data | cause: pii on a query/body field | Prefer smart_replace_recorded (maps recorded values) over a blind mask — the value selects WHICH mock answers |
| Auth material | cause: jwt, or an auth/api-key/cookie header | Do NOT auto-accept. Surface to the user: masking can create false matches; token re-signing or a credentials preflight is usually the right fix |
| IDs inside JSON bodies | body-leaf recs, incl. embedded-JSON paths | Accept the body-field rec |
| Opaque low-confidence drift | cause: opaque | Inspect with mocks action=similar and reason: a real discriminator must NOT be masked (it would return the wrong mock) |
| SQL traffic drifting | sql tech in the misses | Check sql_report before masking — literal values in statements often need a different strategy |

## Reading mocks action=similar causes

- **datetime / uuid / trace-id / ip / random** — high-confidence noise; mask.
- **pii (low confidence)** — likely a record-selecting key (email, phone). smart_replace_recorded, not a mask.
- **jwt** — credential; stop and ask the user.
- **opaque (low confidence)** — could be a real discriminator or a correlated id; decide from the values shown, and when in doubt leave it and tell the user.
- **"No similar recorded signatures"** — the endpoint's traffic is absent from the snapshot. No transform fixes that; the snapshot needs to be re-recorded covering that code path.

## Hard rules

- Blueprint-only changes. Never edit_rrpair or delete_rrpairs to force matches.
- Prefer narrowly scoped fixes (the group's filter) over global masks.
- Accepting and undoing are idempotent — experiments are cheap; regressions are not acceptable in the final state.
- smart_replace_recorded fixes cannot be credited by the offline projection (they need recorded data at replay time). "Applied but still projected-miss + smart_replace" is expected — don't churn through alternatives; note it for the replay to confirm.
- A projected 100% is a projection, not a guarantee — say so in the report and recommend a confirming replay.

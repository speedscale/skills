# Diagnosing and classifying a failing replay

## Evidence order

Pick the **one** biggest problem in the scoreboard, then work down this list and
stop as soon as it explains the problem:

1. **The first failing response body.** Read the replayed response next to the
   recorded one for the top failing endpoint (local: the pair's `replayFile` and
   `sourceFile` from `replay-verdict.json`; cloud: the pair in
   `generator-pairs.jsonl` or `proxymock/report-<id>/`). State in one sentence
   what differs.
2. **Mock outcomes** for the calls that endpoint makes: `MISS` (`NO_MATCH` in
   older output) and `PASSTHROUGH` calls around the same time. If these explain it, it is a mock
   problem: hand off.
3. **Logs:** locally the app log and the `proxymock mock` log; in the cloud
   `generator-log.jsonl`, `responder-log.jsonl` and the report's replay events
   with their suggested fixes (`proxymock cloud replay status <id>`, or
   `watch-replay.sh` from `run-snapshot-replay` on older proxymock).
4. **proxymock's own suggestions:** `proxymock recommendations list --in
   <workspace>` (generator-side transforms).

## Classification

| Side | Symptom | Likely cause | The one change to try |
| --- | --- | --- | --- |
| Mock | `MISS`, `PASSTHROUGH`, low match rate | a signature that no longer matches, a call never recorded, or the app bypassing the proxy | not this skill: hand off to `improve-mock-match-rate`. For proxy bypass, see the mocking check in `run-snapshot-replay` |
| Generator | 401 or 403 where the recording had 2xx | expired or re-signed credential | `recommendations list --type transform` for JWT re-signing, or a credentials preflight; ask before changing auth |
| Generator | 404 or empty result for an ID the app should know | an ID created earlier in the session (order, user, cart) is replayed verbatim but the app issued a new one | a correlation transform that carries the new value forward (recommendations often propose it); otherwise author one |
| Generator | 409 or duplicate errors | the app keeps state between runs: the recorded create already exists | reset or seed the environment; or make the key unique per run with a transform |
| Generator | body differs only in timestamps, generated IDs or ordering | response field legitimately varies | first prove it: the same field varies between two recorded responses, or across two replays with no code change (`proxymock drift --source <run1> --source <run2>`). Then exclude it in the test config assertions ([test-config.md](test-config.md)); the default config already ignores UUID and timestamp values |
| Generator | a field or status changed for no data reason | **the SUT behaves differently** | stop tuning this endpoint. It is a finding: endpoint, field, recorded vs replayed |
| Either | everything fails from one point on | a setup call failed (login, handshake, session): the rest cascade | fix the first failure only, then re-run |
| Environment | connection refused, timeouts, pods restarting, replay Error | the run itself broke | fix or report the environment; it is not a tuning problem, and does not count against the budget if nothing ran |

## Which lever, for a volatile field

- A field that changes on every response and never matters (`generated_at`, a
  request timestamp): exclude it from the test config assertions, after
  `proxymock drift` shows it varies between two runs. Prove it first.
- A value the app minted during the session that later requests must reuse (a
  new order id): a correlation transform, not an exclusion.
- A field whose change reflects new behavior: a finding. Do neither.

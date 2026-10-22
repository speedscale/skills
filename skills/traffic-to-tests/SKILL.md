---
name: traffic-to-tests
description: Turn the inbound requests in a proxymock recording or a Speedscale snapshot into unit or integration tests for one service, written in the repository's own language and test framework, using the recorded requests as inputs, the recorded responses as expectations and the recorded outbound calls as fakes. Picks a few representative cases per endpoint and status (error paths included), never asserts volatile values such as IDs, timestamps and tokens, runs the new tests and reports which pass. Use when users ask to write tests from recorded traffic, turn a snapshot or RRPairs into unit tests, generate test cases for a service from production traffic, or add test coverage from a recording. For a replay-based regression gate rather than test code, use proxymock-regression-test.
argument-hint: --in <recording-dir> | --snapshot-id <id> [--service <name>] [--level unit|integration]
---

# Traffic to tests

Turn recorded traffic into ordinary tests that live in the repository, run with
its own test command, and get reviewed like any other code. The recording
supplies real requests, the responses the service gave, and the calls it made
to its dependencies while answering. The repository supplies the language, the
test framework, the fakes and the conventions. The output is test code, not a
proxymock run.

This is different from **proxymock-regression-test**, which replays the whole
recording at a running app and gates on proxymock's verdict. Use that skill for
a replay gate; use this one when the user wants test cases in the codebase.

Terms (RRPair, inbound, outbound, HIT/MISS) are defined in
[`quality-loop`](../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill).

## 1. Get the recording

- **Local recording:** a `proxymock/recorded-<name>` directory. No recording
  yet: make one with [`record-traffic`](../record-traffic/SKILL.md).
- **Speedscale snapshot:** pull it into the project, which needs proxymock
  signed in (the install-speedscale skill covers sign-in):

  ```bash
  proxymock cloud pull snapshot <snapshot-id>   # lands in proxymock/snapshot-<id>
  ```

Recordings hold real traffic.

- **Git:** check that `proxymock/` is ignored. If it is not, propose adding it
  to `.gitignore` and ask before editing that file.
- **Personal data:** if the traffic may carry real customer data, redact it
  locally with `proxymock dlp` before reading further (quality-loop's
  [recording-to-scenarios](../quality-loop/references/recording-to-scenarios.md),
  step 2). Values on reserved test domains such as `example.com` are synthetic.
  Ask the user when you cannot tell.
- **Fixtures:** tests get small, sanitized fixtures, never the raw RRPair files.

## 2. Pick the service and the cases

Run the bundled selector by its path inside this skill's installed directory
(`<skill-dir>` is the folder holding this `SKILL.md`). It needs `python3`. `--in` is the recording
or the pulled snapshot (`proxymock/recorded-<name>` or
`proxymock/snapshot-<id>`). First list what it holds:

```bash
<skill-dir>/scripts/select-cases.sh --in proxymock/snapshot-<id> --list
```

It prints each inbound service with its endpoints, statuses and counts. A
snapshot from a cluster can hold several services; ask the user which one to
test when the request does not say, and confirm the service lives in this
repository. Then select the cases:

```bash
<skill-dir>/scripts/select-cases.sh --in proxymock/snapshot-<id> \
  --service <name> --per-endpoint 2 --out proxymock/results/test-cases.json
```

For every endpoint and status it keeps up to N distinct exchanges (default 2).
Exchanges whose bodies differ only in IDs and timestamps count once, even when
the IDs are in the path, and identical requests that got different answers (a
list that grew) count separately; `recorded` and `distinct` say how many there
were. Each case gives:

- `request`: method, path with query, headers, the parsed body and `rawBody`,
  the exact text sent (use it for malformed-body cases). Credential headers
  read `<redacted>`.
- `response`: the recorded status, headers and body. This is the expected
  behavior. `volatileHeaders` names headers such as `Date` that change on every
  response: do not assert their values.
- `volatile`: response fields holding UUIDs, timestamps or tokens, with array
  indexes collapsed to `[*]`, and the `source` of each value:
  - `request`: it echoes the request (an ID from the path). Assert it equals
    the request's value.
  - `dependency`: a dependency returned it (a database row, an upstream body).
    Once the fake returns the recorded value it is deterministic: assert it.
  - `generated`: the service made it (a clock, a random ID). Pin it through the
    repository's seam (an injected clock or ID generator) when there is one,
    and assert the pinned value. A clock read more than once per request (a
    cutoff and a timestamp) needs a fake that returns the recorded values in
    order. Without a seam, assert the shape, and when `alsoSentTo` names a
    dependency call, assert the response value equals the one sent there (the
    generated ID the service wrote to the database).
- `dependencies`: the calls the service made while handling the request, in
  order.
  - **HTTP:** method, path, query, status, `responseContentType` and the
    response body. A body too large to inline is written beside `--out`, and
    `responseBodyFile` names it. `volatileQuery` and `volatileHeaders` name the
    parts that change on every call (`?ts=`, `X-Request-Id`): stubs match on
    method and path, never on those.
  - **SQL:** the statement, decoded parameters and decoded result rows, and the
    completion tag. Protocol bookkeeping (prepare, describe, bind) is left out;
    transaction statements (`begin`, `commit`) stay, so assert them only when
    the repository's fakes model transactions. `volatileParams` flags
    parameters that change between runs with the same `source` meanings, plus
    `response` for a value the response also returns. A parameter derived from
    the clock (a cutoff an hour back) shows as `generated`; pin the clock and
    the parameter follows. A value the decoder cannot read stays as
    `undecoded` base64 with its type OID.
  - A case marked `dependenciesApproximate` overlapped another request in time,
    so its list can hold calls made for the other request. Prefer cases without
    the mark.

Inbound HTTP and gRPC are covered. A service whose input is a queue (a Kafka
consumer) has no inbound requests to select; say so rather than inventing them.

## 3. Read the repository before writing anything

Find, and reuse:

- **The test command and framework** (`go test`, pytest, Jest or Vitest, JUnit
  with MockMvc, xUnit), where tests live, and how they are named.
- **The entry point a test can call in-process**: the router or handler
  constructor (`httptest` with the mux, FastAPI `TestClient`, supertest on the
  Express app, `MockMvc`, `WebApplicationFactory`).
- **How dependencies are injected**: interfaces, constructor parameters,
  dependency-injection containers, or base URLs read from the environment. Also
  look for a clock or ID-generator seam.
- **Which code issues each recorded SQL statement.** Search the code for the
  statement text to find the repository method, so the fake for that method is
  seeded with the recorded rows.
- **Existing fakes, fixtures and helpers.** Reuse their types. When an existing
  fake serves fixed data that differs from the recording, add a
  recording-backed variant beside it rather than changing what existing tests
  rely on.

If a dependency cannot be replaced without changing production code (a client
built inside the handler, a global connection), stop and propose the smallest
seam to the user. Do not change production code without asking.

## 4. Choose the level

Follow what the repository already does; ask when it does neither.

**Unit (in-process, the default).** Call the handler or router directly with the
recorded request and assert the recorded response. Answer each dependency with
what the recording says it returned:

- An HTTP dependency: a local stub (`httptest.Server`, `respx`, `nock`, MSW,
  WireMock) returning the recorded body for the recorded method and path, or
  the repository's fake client.
- A database: the repository's own fake or in-memory store, seeded with the
  decoded rows from `dependencies`. Do not hand-write a wire-protocol database
  fake.

**Integration (app process, real wiring).** Start the app with its dependencies
answered by proxymock from the same recording, then send the recorded requests
over HTTP with the language's client:

```bash
proxymock mock --in proxymock/snapshot-<id> \
  --map <port>=postgres://<recorded db host:port> --app-health-endpoint /healthz \
  --out proxymock/results/mocked-<ts> -- <app run command>
```

Reuse every `--map` the recording used, from the command that recorded it (see
record-traffic) or the project README. Put the start and stop in the test
suite's setup, or in the CI job that runs the suite, the way the repository
already starts services for tests. The mock must answer from a committed,
sanitized copy of the recording, not from `proxymock/`. Check the mock run with
`proxymock replay score` or improve-mock-match-rate when the tests fail on a
dependency call.

## 5. Write the tests

- **One test case per selected case**, grouped by endpoint and status and
  table-driven where the language makes that idiomatic. Name each after what it
  shows (`creates an order and prices it from the catalog`, `returns 404 for an
  unknown order`), not after the RRPair file.
- **Error paths are tests too.** Recorded 4xx and 5xx responses become negative
  cases with their recorded status and error body.
- **Assert** status, content type and every response field, treating volatile
  fields by their `source` as described in step 2.
- **Dependency calls:** when the repository's tests already check calls (a
  fake that records them, a stub that counts requests), also assert the
  recorded calls: which upstream paths were requested, which store methods ran,
  and what was written.
- **Order:** assert the order of a list when the service sorts it, or passes
  through an order the fake reproduces (an upstream list served from the
  recording). When the order comes from the dependency (`ORDER BY` in SQL) and
  the repository's fake does not reproduce it, compare without order.
- **Fixtures:** keep each case's request, response and dependency data in files
  under the repository's fixture directory (`testdata/`, `tests/fixtures/`,
  `src/test/resources/`). Keep them as small as the expectation allows: trim
  what no assertion and no dependency answer needs, but keep a full dependency
  body when the response is built from it. Never copy RRPair metadata,
  `<redacted>` values, real credentials or personal data into fixtures; replace
  them with obvious synthetic values.
- **Dependencies get exactly what they returned in the recording**, so the test
  pins the service's own logic, not the dependency's.
- Write `test-cases.json` and other scratch output under `proxymock/results/`.
  It is not a test artifact.

## 6. Run them, and keep the expectations honest

Run the repository's test command for the new tests. Fix harness problems
(imports, fixture paths, wiring) and rerun. Then change one recorded expectation
in a fixture, confirm the test fails with a readable message, and put it back,
so a test that cannot fail is caught.

When a test fails because the service's answer differs from the recording, do
not edit the expectation to match the code. It is either a real behavior change
since the recording, a value that should have been treated as volatile, or a
dependency the fake answers differently. Say which, with the field and both
values, and let the developer decide. Never loosen an assertion, skip a case, or
mark it expected to fail to get a green run.

Ask before starting the app, a database or proxymock, and before touching any
file outside the tests and their fixtures.

## Related

- **record-traffic** makes the recording; **proxymock-summarize-recording**
  describes it in more depth.
- **proxymock-regression-test** gates on a full replay instead of test code.
- **proxymock-contract-test** checks the same traffic against an OpenAPI spec.
- **improve-mock-match-rate** when integration tests fail on a mocked
  dependency.

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

For this skill: **Ran** is the recording or snapshot, the service, the level
(unit or integration) and the test command. **Outcome** is how many new tests
pass, and the cases that fail with the reason for each. **Numbers** are the
endpoints covered out of those recorded, the tests written, the error-path
cases, and the cases left for the developer to decide. **Artifacts** are the new
test files and fixtures, not the scratch output under `proxymock/results/`.
**Next** is usually adding the tests to CI, or proxymock-regression-test for a
full-replay gate.

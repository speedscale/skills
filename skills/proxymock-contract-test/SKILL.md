---
name: proxymock-contract-test
description: Contract-test recorded or replayed traffic against an OpenAPI spec or a gRPC .proto with proxymock validate, reporting exact field-path violations, and mock a dependency straight from its spec with proxymock generate before any recording exists. Use when users ask whether a dependency's behavior matches its spec, to validate recorded traffic against an OpenAPI or protobuf contract, or to mock an HTTP or gRPC API from its spec alone.
argument-hint: --spec <openapi.(json|yaml) | service.proto> --in <rrpair-dir>
---

# proxymock Contract Test

Contract testing from the assets the quality loop already has: an OpenAPI 3.0+
spec or a gRPC `.proto`, and RRPair traffic. One native command:

```bash
proxymock validate --spec ./openapi.yaml --in ./proxymock/recorded-<name>/<dependency-host>
```

It matches each HTTP RRPair to a method and route in the spec (path templates
included), checks the response body for type, required fields, enum values and
undocumented fields, resolves local and component `$ref`s, and parses YAML
itself — no PyYAML, no `ruby -ryaml`.

**Requires proxymock v2.5.814 or newer.**

## Choose the boundary and its schema

Validate outbound dependency responses against that dependency's accepted schema, or inbound application responses against the application's accepted schema. Select the corresponding traffic and spec. `NO_ROUTE` means the selected spec lacks that method/path; it does not mean inbound contracts are unsupported.

Validation measures response shape, required fields, status definitions and response properties. It does not validate request boundaries or establish business values. Pair it with accepted regression expectations and explicit negative request cases.

## Works with your stack (no bash required)

```bash
# does the dependency's recorded behavior match its spec?
proxymock validate --spec ./openapi.yaml \
  --in ./proxymock/recorded-<name>/<dependency-host>

# same check against a replay output dir: a violation introduced between
# recording and replay is a change your code made
proxymock validate --spec ./openapi.yaml --in ./proxymock/results/<replay-run>
```

| Exit | Meaning |
| --- | --- |
| `0` | every checked pair conformant |
| `2` | violations found (each printed with its exact JSON path) |
| `3` | no violations, but at least one pair's route is missing from the spec (`NO_ROUTE`) |
| `1` | precondition failure: unreadable spec, missing directory, no HTTP pairs |

Violations print with full attribution, e.g.
`$[0].stars: type mismatch, expected integer, got string ("many")`, and the run
ends with `checked 5 pair(s): 4 conformant, 1 violating, 0 without a spec
route`. Any CI system in any language can gate on those exit codes; the bundled
`quality-loop.sh contract` is optional convenience that builds this exact line.

**`validate` treats undocumented response fields as violations.** There is no
flag to downgrade them. If additive response fields are non-breaking for you,
filter them out of the report yourself or expect the exit 2 and read the
violation list rather than the code.

## gRPC contracts from a .proto

The same three commands take a `.proto`; the spec type is detected from the
file extension. `-I`/`--proto-path` (repeatable) adds import roots, and the
spec's own directory is always searched.

```bash
proxymock validate --spec ./proto/orders/v1/orders.proto -I ./proto \
  --in ./proxymock/recorded-<name>
proxymock coverage --spec ./proto/orders/v1/orders.proto -I ./proto \
  --in ./proxymock/recorded-<name> --json
proxymock generate --direction outbound -I ./proto --out ./generated \
  ./proto/orders/v1/orders.proto
```

- **validate** matches each gRPC RRPair to `/package.Service/Method` and
  checks the decoded response message: a wire type that contradicts the
  declared field type, an enum number the enum does not declare, a field
  number the message does not declare, and missing proto2 `required` fields.
  Paths use `.proto` field names, e.g.
  `$.items[0].quantity: type mismatch, expected int32, got length-delimited ("lots")`.
  Proto3 fields without explicit presence are never "missing": a zero value is
  not on the wire. A call that ended with a non-OK gRPC status carries no
  message and conforms. Exit codes are the same as for OpenAPI.
- **coverage** reports every RPC as an operation (`POST /package.Service/Method`),
  gRPC status names (`OK`, `NOT_FOUND`) as statuses, and response message
  fields as fields, in the same JSON shape.
- **generate** writes one RRPair per unary RPC as gRPC over HTTP/2, the way
  proxymock records it, so `proxymock mock` serves it to a gRPC client and
  `proxymock replay` sends it to a gRPC server unchanged. Streaming RPCs are
  listed as skipped. `--include-paths` and `--exclude-paths` take
  `/package.Service/Method` globs or a bare `/package.Service`, and
  `--tag-filter` is rejected. Messages follow the rules below: implicit-presence
  fields are set, `optional` fields only with `--include-optional`, the first
  member of each `oneof`, and the first non-zero enum member.

## Mocking a dependency from its spec, before any recording exists

```bash
proxymock generate ./openapi.yaml --out ./generated --include-optional
proxymock mock --in ./generated
```

Generated output is **smoke/plumbing tier**: good for developing against a
dependency before a recording exists, proving wiring, and exercising client
code paths. It is not logic-grade data. All measured:

- **Required-only bodies by default.** Pass `--include-optional` for fuller
  payloads.
- **Arrays are 2 identical stub items.** An app aggregating over them sees a
  degenerate distribution.
- **Example-less fields get the literal `"example_value"`.** Enum fields are
  the exception — they get a real member of their enum, so generated bodies
  pass `validate` against the spec they came from. Add `example:` values where
  a plausible string matters.
- **One response per status.** No response variety within a status code. A
  `.proto` yields one `OK` response per RPC and no error statuses.
- **Path params become match-any templates** (`${{param:id}}` matches any
  concrete id), including params the spec constrains with an enum.

With `--direction inbound` the output is tests for your own service, and the
run ends with a `PLACEHOLDERS:` list of tests whose request still sends
`example_value` or `${{param:...}}`. Those are drivers for a first recording,
not a baseline: the quality-loop
[bootstrap workflow](../quality-loop/references/bootstrap.md) rewrites them and
records the app's real responses.

## Interpretation

- **VIOLATION on recorded traffic**: the dependency drifted from its spec, or
  the spec is stale. The recording is evidence of real behavior, so treat it as
  "spec and reality disagree" and decide which is wrong; the JSON path names
  the exact field.
- **VIOLATION on replayed traffic**: same check, but the responses came from
  your mock or your app under test, so a violation introduced between recording
  and replay is a change your code made.
- **NO_ROUTE (exit 3)**: for a dependency host, the spec is incomplete. For inbound application pairs, check the app schema and operation before changing the case.
- **undocumented-field violations**: additive response fields are usually
  non-breaking, but `validate` scores them as violations regardless. Decide
  from the violation text, not from the exit code alone.
- **Green conformance is not a behavior gate.** Schema conformance checks
  shape, not values or ordering; a wrong-but-well-typed response passes. Pair
  with proxymock-regression-test for behavior.

For coverage expansion and saved scenarios, follow [quality-loop](../quality-loop/SKILL.md). Generated schema cases are candidates until exercised and accepted; never weaken the schema to make a replay pass.

## Related

- **proxymock-regression-test**: when the app
  has no spec, the recording is the contract and replay is the gate.
- **proxymock-summarize-recording**: see what hosts and routes a recording
  contains before pointing `--in` at it.
- **quality-loop**: the router, and its `doctor`.

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

For this skill: **Ran** is the spec and the traffic directory checked (or the
spec a mock was generated from). **Outcome** is `conformant`, `violations` or
`no spec route`, with the exit code. **Numbers** are pairs checked, conformant,
violating and without a route. **Artifacts** are the generated mock directory,
if any. **Next** is `proxymock-regression-test` for the app's own behavior.

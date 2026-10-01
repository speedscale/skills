# Test config: the assertion lever

Read on demand from `SKILL.md` when a volatile field needs excluding, or when a
run should be scored more strictly than the default. Terms (accuracy,
passAssertPct, verdict) are defined in
[`quality-loop`](../../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill).

## What the default already does

A local replay without `--test-config` uses the built-in `regression` config. Its
body scoring already ignores values shaped like UUIDs and timestamps, so a
generated `id` or a `generated_at` often passes with no tuning at all. Run the
default first: if accuracy is already at target there is nothing to exclude.
The built-in `standard` config asserts more (status, headers, cookies, body,
content type) and scores lower on the same run, which is the reason to pick it
when headers or cookies matter, not a sign the app got worse.

## Create a workspace config

A config is one complete TestConfig as JSON at `proxymock/testconfigs/<name>.json`,
read strictly (an unknown field is an error naming it).

```bash
if proxymock test-config new --help 2>/dev/null | grep -q 'test-config new'; then
  proxymock test-config new <name> --from standard
else   # older builds: compile a built-in, set its id, drop the built-in-only flag
  mkdir -p proxymock/testconfigs
  proxymock test-config compile standard 2>/dev/null \
    | jq '.id = "<name>" | del(.protected)' > proxymock/testconfigs/<name>.json
fi
```

Then edit the assertion you need. The groups live under
`assertionGroups[].configs[]`, one entry per assertion `type`:
`httpStatusCode`, `httpHeaders`, `httpResponseCookies`, `httpResponseBody`,
`httpResponseContentType`. `proxymock test-config meta` lists which fields each
run path honours (it does not list assertion keys on older builds; the keys
below come from the asserters).

| Assertion | `config` key | Effect |
| --- | --- | --- |
| `httpResponseBody` | `ignore` | comma-separated JSON fields to skip |
| `httpResponseBody` | `includeOnly` | compare only these fields |
| `httpResponseBody` | `allowNew` | `"true"`: fields only the replay has do not fail |
| `httpHeaders` | `headers` | comma-separated header names to compare (others skipped) |

The volatile-field example, ignoring two fields the app regenerates on every call:

```json
{"type": "httpResponseBody", "config": {"ignore": "generated_at,id"}}
```

Or with jq, on the config you just created:

```bash
jq '(.assertionGroups[].configs[] | select(.type == "httpResponseBody"))
    |= (.config = {ignore: "generated_at,id"})' proxymock/testconfigs/<name>.json \
  > /tmp/tc.json && mv /tmp/tc.json proxymock/testconfigs/<name>.json
proxymock test-config compile <name> >/dev/null   # validate before running
```

Run it with `proxymock replay ... --test-config <name>`, and use the same config
for every later run and for the regression gate. With a test config the config's
goals (`passAssertPct >= 100` by default) decide the exit code.

## Prove a field is volatile before excluding it

Replay the same recording twice on the same code, then compare:

```bash
proxymock drift --source proxymock/results/replayed-1 --source proxymock/results/replayed-2
```

A field listed there took different values across runs with no code change, so
it is legitimately volatile. A field that does not drift is not: leave it
asserted, and if it fails, that is a finding. `drift` aggregates fields, so
`--sensitivity strict` cuts one-off noise. A value the app minted that later
requests must reuse is a correlation transform, not an exclusion.

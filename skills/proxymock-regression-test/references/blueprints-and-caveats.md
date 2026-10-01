# Regression gate: measured caveats and blueprints

Measured on proxymock v2.5.814. Read on demand from `SKILL.md`.

## Two caveats on the gate

**Baseline masking compares CHANGE SETS, not just pairs.** A pair that already
failed in the baseline is exempt from *that same failure*, not from every later
one. Verified both ways: an identical failure stays masked and the run exits 0;
the same pair failing *differently* (a 401 that starts returning 500, or a body
change at a location the baseline did not fail at) is caught as a new mismatch
and exits 3.

**Volatile suppression follows value patterns.** The built-in scoring ignores
values shaped like UUIDs and timestamps (the default `regression` config does
the same for its assertions), whatever the field is called. A value that varies
without looking like either (a counter, a short random token) is scored. So a raw
`bodyMismatches: 0` is not proof of a stable app: establish a `--baseline` and
gate on NEW mismatches, which keeps the gate green on a recording whose app
mints fresh values every run. The stricter built-in `standard` config also
asserts headers and cookies, so it fails more pairs on the same run.

## Blueprints: the part that silently costs you the signal

An app with moving IDs (rotating tokens, generated order ids) needs a blueprint
to chain them through the replay. Without one, the auth and moving-ID endpoints
401, and **a regression on their success paths is undetectable** because they
fail before and after the change.

- **Where blueprints load from.** The workspace `proxymock/blueprints/`
  directory (the parent of the recording dir) loads, and a `blueprints/` copy
  *inside* `--in` loads too, because replay reads `--in` recursively.
  Workspace discovery is **not reproducible across identical recordings under
  different names**: a byte-identical copy of a recording under a different
  directory name in the same workspace, beside the same `blueprints/`, did not
  pick it up. If a workspace blueprint does not load, a copy inside `--in` is a
  local workaround, but do not relocate a shared, committed blueprint to work
  around it.
- **Confirm it loaded** with the `Loaded blueprint "<name>" from <path>` line
  in the replay output. Never move a blueprint the log says is loading.
- **The hostname trap (this one costs you the whole run).** Replay rewrites the
  recorded network address to the `--test-against` target, so a blueprint that
  filters on `network_address` binds itself to one spelling of that target. With
  a filter of `network_address CONTAINS "localhost"`, `--test-against
  localhost:8080` fired both chains, while `--test-against 127.0.0.1:8080`
  **loaded the blueprint and fired ZERO chains, with no warning**. Same `Loaded
  blueprint` line either way. A loaded-but-inert blueprint is usually this.
  Filter on `detectedLocation` / `detectedCommand` and scope with `services`.
- **`--require-blueprint <name>` works, and is opt-in for a reason.** On
  v2.5.814 it exits 0 and still writes `replay-verdict.json` when the blueprint
  loaded and its chains ran; on an unresolvable name it exits 1 and writes **no
  verdict file at all**. Gating on it trades the entire regression signal for a
  blueprint warning. Add it when a silently inert blueprint is the bigger risk;
  otherwise check the `Loaded blueprint` line and grep the replay output for
  `smart_replace`.

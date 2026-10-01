# Check that local mocking took effect

Read on demand from `SKILL.md` step 3. Terms (HIT, MISS, PASSTHROUGH, measured
match rate) are defined in
[`quality-loop`](../../quality-loop/SKILL.md#terms-used-the-same-way-in-every-skill).

Local mocking depends on the app sending its outbound calls through
`proxymock mock`, which does not always happen, and a replay that passes says
nothing about it: calls that reached real services still return answers.

## The check

```bash
proxymock replay score <replay run> [--mock-run <mock run>] -o json
```

Read `matchRate` (`rate`, `matched`, `noMatch`, `passthrough`, `total`,
`topMissingHosts`, `mockRun`). `mockRunSelection` says whether the mock run was
paired by time overlap or given with `--mock-run`. Newer proxymock pairs runs
under `proxymock/results/` by itself; older builds fail with "not inside a
proxymock workspace" unless `--mock-run` is passed.

| What you see | What it means | Tell the user |
| --- | --- | --- |
| `total` is 0, or the mock run has no pairs | The app did not use the proxy: proxy env vars not honoured, a client that ignores them, or a database driver that needs `--map` | "Mocking did not take effect: the app reached its real dependencies." Name the likely cause for the app's language or client |
| `passthrough` above 0 | Those calls went to real services: the host is not in the recording, the protocol is not mocked, or a `--map` is missing | List the hosts and say the results for them came from real services |
| `noMatch` above 0 | The mock had the host but no recorded request matched; the app got an error from the mock | List the top signatures; `improve-mock-match-rate` is the fix |
| `rate` 100, `passthrough` 0 | Fully mocked | Report the measured rate |
| No mock run at all | The mock server never started or wrote nothing | Say mocking status is unknown, and why |

## Which hosts passed through

`topMissingHosts` can be empty even when `passthrough` is not. List them from
the mock run directly (one directory per host; each pair carries its outcome in
its tags, as `match=PASSTHROUGH` in markdown or `"match": "PASSTHROUGH"` in
JSON):

```bash
grep -rl PASSTHROUGH <mock run> | sed "s#^<mock run>/##; s#/.*##" | sort | uniq -c
```

A database mapped to a port on this machine writes its pairs under
`localhost-<port>/` (older proxymock builds used `localhost/`, next to the HTTP
ones), so count passthrough per directory and read the database ones separately.

If you cannot tell (no outbound recording to compare against, or the app was
started outside your control), say that mocking is unverified rather than
guessing.

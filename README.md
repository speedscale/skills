# Speedscale agent skills

Skills that teach an AI coding agent (Claude Code, Cursor, Codex, Gemini CLI,
OpenCode, Kiro, or anything that can read a URL) how to install, tune, and
verify [Speedscale](https://speedscale.com) and
[proxymock](https://proxymock.io).

## Install Speedscale with your agent

Paste this into your assistant. It fetches the skill, saves it, then follows it:

```
Install Speedscale for me. First fetch the agent skill at
https://raw.githubusercontent.com/speedscale/skills/main/skills/install-speedscale/SKILL.md
and the references/ and scripts/ files it links to (same base URL), save them
under your skills directory, then follow the skill. Ask me before touching a
Kubernetes cluster.
```

The skill installs the `speedctl` and `proxymock` CLIs, installs Helm and
kubectl if they are missing, sets up the API key without ever printing it,
installs the Speedscale Operator with values chosen for your platform
(EKS, GKE, AKS, minikube, kind, OpenShift), verifies the result, and wires
the proxymock MCP server into your agent.

## ChatGPT desktop app

Open the ChatGPT desktop app, select Codex, and open your project's folder. The source is the [install-speedscale skill](https://github.com/speedscale/skills/tree/main/skills/install-speedscale). Paste this prompt to install it:

```text
Use $skill-installer to install skills/install-speedscale from the speedscale/skills GitHub repository.
```

In your next message, ask Codex to use it:

```text
Use $install-speedscale to set up Speedscale for my project. Check what is already installed and tell me which components I need. Ask before changing a Kubernetes cluster. Never print my API key.
```

If the new skill does not appear, restart the app. You can also use `$install-speedscale` later for an upgrade or repair.

ChatGPT on the web and mobile cannot install these skills directly from a GitHub URL. Those surfaces can use them after Speedscale publishes a plugin in ChatGPT's plugin directory.

## Other ways to get the skills

| Route | Command |
| --- | --- |
| Claude Code plugin | `/plugin marketplace add speedscale/skills` then `/plugin install speedscale@speedscale-skills` |
| Any agent, via the skills CLI | `npx skills add speedscale/skills` |
| Already have proxymock | `proxymock mcp install --yes` (Claude Code) or `proxymock mcp skills export --dir <your skills dir>` |
| Manual | copy `skills/<name>/` into your agent's skills directory |

## Skills

| Skill | What it does |
| --- | --- |
| [`install-speedscale`](skills/install-speedscale/SKILL.md) | End-to-end install: CLIs, prerequisites, API key, operator Helm chart, verification, MCP wiring, upgrades, uninstall |
| [`analyze-replay-report`](skills/analyze-replay-report/SKILL.md) | Explain a cloud report or a local proxymock replay run: verdict, the first failing response, root-cause bucket, and next steps |
| [`improve-mock-match-rate`](skills/improve-mock-match-rate/SKILL.md) | Pull a replay report and tune mock blueprints until the projected match rate stops improving |
| [`run-snapshot-replay`](skills/run-snapshot-replay/SKILL.md) | Run a snapshot or recording as a replay, locally or in the cloud, defaulting to where it was recorded, and follow it to a verdict |
| [`tune-snapshot-replay`](skills/tune-snapshot-replay/SKILL.md) | Loop until a replay is accurate and fully mocked: measure, change one thing, re-run, keep or revert, with progress kept on disk |

### proxymock quality loop

Skills for testing a service with recorded traffic and no Speedscale Cloud
account. They were developed in [mock-lab](https://github.com/speedscale/mock-lab)
and their examples use its committed fixture, `lab/proxymock/recording`, so
paths like that are relative to a mock-lab checkout. The `prove-*.sh` scripts
need `MOCK_LAB_DIR` pointing at one. They assume proxymock v2.5.814 or newer;
`skills/quality-loop/scripts/quality-loop.sh doctor` warns if yours is older.
Not sure which applies? Start with `quality-loop`: it routes an intent to the
right command.

| Skill | What it does | Wraps |
| --- | --- | --- |
| [`quality-loop`](skills/quality-loop/SKILL.md) | The entry point: route an intent to the right native command or analysis skill, with the setup playbook, blueprint rules, gotcha catalog, and a `doctor` | builds and execs the native commands |
| [`proxymock-regression-test`](skills/proxymock-regression-test/SKILL.md) | Replay a recording at a target and gate on the per-RRPair verdict (status and body) against a known-good baseline | `proxymock replay --baseline --fail-on-new-mismatch` |
| [`proxymock-verify-fix`](skills/proxymock-verify-fix/SKILL.md) | Prove a bug fix by replaying the incident capture at the fixed build | `proxymock replay --verify-fix` |
| [`proxymock-contract-test`](skills/proxymock-contract-test/SKILL.md) | Check recorded or replayed traffic against an OpenAPI spec; mock a dependency straight from its spec | `proxymock validate`, `proxymock generate` |
| [`proxymock-chaos-mock`](skills/proxymock-chaos-mock/SKILL.md) | Inject faults into a mock: 503s, 429s with `Retry-After`, corrupt bodies, latency, connection faults, exact ratios | `proxymock mock --fault` |
| [`proxymock-load-test`](skills/proxymock-load-test/SKILL.md) | Replay at a target with parallel virtual users; latency percentiles, throughput, match rate, `--fail-if` SLO gates | `proxymock replay --vus --for --fail-if` |
| [`proxymock-perf-container`](skills/proxymock-perf-container/SKILL.md) | Load-test one service with its downstream mocked, and judge the number honestly | `proxymock replay --vus --for --load-test` |
| [`proxymock-compare-results`](skills/proxymock-compare-results/SKILL.md) | Deep before/after comparison of two replay or recording sets; JSON, HTML, and an LLM digest | `proxymock report --baseline`, `proxymock drift` |
| [`proxymock-summarize-recording`](skills/proxymock-summarize-recording/SKILL.md) | Summarize a recording: hosts, endpoints, methods, status mix, volume | `proxymock report --format prompt` |
| [`proxymock-replay-tuning`](skills/proxymock-replay-tuning/SKILL.md) | Replay outbound pairs against a local mock and report HIT/MISS/PASSTHROUGH to restore a stale mock set | `tune-proxymock-replay.sh` |

## How this repo is maintained

`install-speedscale` and `improve-mock-match-rate` are mirrored from the
Speedscale monorepo on every proxymock release (`proxymock mcp skills export`),
so they always match what the shipped binary installs; fixes to those two are
applied upstream and flow back on the next release. The quality-loop skills are
maintained here directly, so pull requests against them merge as-is.

Docs: https://docs.speedscale.com · Community: https://slack.speedscale.com ·
Support: support@speedscale.com

Licensed under the Apache License 2.0.

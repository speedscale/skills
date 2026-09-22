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
| [`improve-mock-match-rate`](skills/improve-mock-match-rate/SKILL.md) | Pull a replay report and tune mock blueprints until the projected match rate stops improving |

## How this repo is maintained

`skills/` is mirrored from the Speedscale monorepo on every proxymock
release (`proxymock mcp skills export`), so the files here always match what
the shipped binary installs. Fixes are welcome as pull requests; they are
applied upstream and flow back on the next release.

Docs: https://docs.speedscale.com · Community: https://slack.speedscale.com ·
Support: support@speedscale.com

Licensed under the Apache License 2.0.

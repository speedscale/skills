# Contributing

The skills in `skills/` are generated, not edited here. Each one ships inside the proxymock binary and lives in the Speedscale monorepo under `speedctl/mcp/skills/`. A proxymock release mirrors them into this repository with `proxymock mcp skills export`, replacing every skill listed in `skills/.proxymock-managed`. A change made to a skill in this repository is overwritten by the next release, so make skill changes in the monorepo.

This repository owns:

- `README.md` and this file
- `.claude-plugin/marketplace.json` and `.claude-plugin/plugin.json`. The plugin discovers every directory under `skills/`, so adding or removing a skill needs no manifest change.
- `scripts/check-skills.sh`, which CI runs on every change. Run it locally before pushing:

```bash
sh scripts/check-skills.sh
```

To see the skills a proxymock build ships before a release, export them into a scratch directory:

```bash
proxymock mcp skills export --dir /tmp/skills
proxymock mcp skills list --dir /tmp/skills
```

#!/usr/bin/env python3
"""Checks the plugin manifests against the limits the Claude and OpenAI
plugin directories enforce. Run from the repo root; exits 1 on any problem."""
import json
import re
import struct
import sys

problems = []


def fail(msg):
    problems.append(msg)


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as e:
        fail(f"{path}: {e}")
        return {}


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", head[16:24])


def check_icon(path, where):
    if not path.startswith("./"):
        fail(f"{where}: icon path {path} must start with ./")
        return
    try:
        size = png_size(path[2:])
    except OSError:
        fail(f"{where}: icon {path} not found")
        return
    if size is None:
        fail(f"{where}: icon {path} is not a PNG")
    elif size[0] != size[1] or size[0] < 48:
        fail(f"{where}: icon {path} must be square and at least 48x48, got {size}")


claude = load(".claude-plugin/plugin.json")
claude_mkt = load(".claude-plugin/marketplace.json")
portable = load("plugin.json")
codex_mkt = load(".agents/plugins/marketplace.json")

# Claude Code caches a plugin by its version; a pinned version hides every
# skill sync from existing installs, so installs track the commit SHA instead.
if "version" in claude:
    fail(".claude-plugin/plugin.json: remove version so installs track the commit")
for p in claude_mkt.get("plugins", []):
    if "version" in p:
        fail(".claude-plugin/marketplace.json: remove version from plugin entry")

names = {
    ".claude-plugin/plugin.json": claude.get("name"),
    "plugin.json": portable.get("name"),
}
for p in claude_mkt.get("plugins", []) + codex_mkt.get("plugins", []):
    names.setdefault("marketplace entries", p.get("name"))
if len(set(names.values())) != 1:
    fail(f"plugin name differs across manifests: {names}")

if "icon" in claude:
    check_icon(claude["icon"], ".claude-plugin/plugin.json")

if not re.fullmatch(r"\d+\.\d+\.\d+", portable.get("version", "")):
    fail("plugin.json: version must be semver (required for Codex submissions)")
if not portable.get("author", {}).get("name"):
    fail("plugin.json: author.name is required")

ui = portable.get("extensions", {}).get("com.openai", {}).get("interface", {})
limits = {
    "displayName": 30,
    "shortDescription": 30,
    "longDescription": 4000,
    "developerName": 80,
}
for field, limit in limits.items():
    value = ui.get(field, "")
    if not value:
        fail(f"plugin.json: interface.{field} is required")
    elif len(value) > limit:
        fail(f"plugin.json: interface.{field} is {len(value)} chars, limit {limit}")
if not ui.get("category"):
    fail("plugin.json: interface.category is required")
for field in ("websiteURL", "supportURL", "privacyPolicyURL", "termsOfServiceURL"):
    if not ui.get(field, "").startswith("https://"):
        fail(f"plugin.json: interface.{field} must be an https URL")
prompts = ui.get("defaultPrompt", [])
prompts = [prompts] if isinstance(prompts, str) else prompts
if len(prompts) > 3 or len(set(prompts)) != len(prompts):
    fail("plugin.json: interface.defaultPrompt allows up to 3 unique prompts")
for prompt in prompts:
    if len(prompt) > 128:
        fail(f"plugin.json: defaultPrompt over 128 chars: {prompt}")
if not re.fullmatch(r"#[0-9A-Fa-f]{6}", ui.get("brandColor", "#000000")):
    fail("plugin.json: interface.brandColor must be #RRGGBB")
for field in ("logo", "composerIcon"):
    if field not in ui:
        fail(f"plugin.json: interface.{field} is required for Codex")
    else:
        check_icon(ui[field], f"plugin.json interface.{field}")

onboarding = portable.get("extensions", {}).get("com.openai", {}).get("onboardingSkill")
if onboarding:
    try:
        open(onboarding[2:]).close()
    except OSError:
        fail(f"plugin.json: onboardingSkill {onboarding} not found")

for p in problems:
    print(f"FAIL {p}")
if problems:
    sys.exit(1)
print("ok   plugin manifests")

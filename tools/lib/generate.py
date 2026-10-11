#!/usr/bin/env python3
"""Render every generated file of the marketplace from its sources.

Sources: plugins/<plugin>/plugin.source.json, roster/agents.json, roster/briefs/<agent>.md,
roster/templates/*, shared/sh/*.sh (copied into each plugin that runs shell).

Usage: generate.py [--check] [--root DIR]
  --check  compare with the files on disk, print stale paths, exit 1 on drift, write nothing.
Needs python3 >= 3.9 and nothing else.
"""
import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rules  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugins", "standards", "skills", "init", "scripts"))
import render_agents  # noqa: E402  (the plugin ships the renderer; init uses it for project rosters)

AUTHOR = {"name": "Filip Karagiannis"}
# The agent templates and the roster defaults (tiers, model map) are copied into the standards
# plugin, which renders project rosters with them.
AGENT_TEMPLATES_DIR = "plugins/standards/templates/agents"
# shared/sh/*.sh is copied into every plugin that runs shell: plugins cannot read each other.
SHARED_SH_DIRS = ["plugins/standards/hooks", "plugins/flow/lib"]
MARKETPLACE_NAME = "brain-plugins"
MARKETPLACE_DESCRIPTION = "Filip Karagiannis's Claude Code and Codex plugins: standards, flow, craft, meta."


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def dump_json(data):
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def yaml_str(value):
    return json.dumps(value, ensure_ascii=False)


def load_plugins(root):
    plugins = []
    for source in sorted(glob.glob(os.path.join(root, "plugins", "*", "plugin.source.json"))):
        data = read_json(source)
        data["_dir"] = os.path.dirname(source)
        plugins.append(data)
    plugins.sort(key=lambda p: p["name"])
    return plugins


def render_plugin(plugin, roster, root):
    """Return {relative_path: content} for one source-driven plugin."""
    out = {}
    rel = os.path.relpath(plugin["_dir"], root)
    out[os.path.join(rel, ".claude-plugin", "plugin.json")] = dump_json({
        "name": plugin["name"],
        "version": plugin["version"],
        "description": plugin["description"],
        "author": AUTHOR,
    })
    codex = plugin.get("codex", {})
    interface = {
        "displayName": codex.get("displayName", plugin["name"]),
        "shortDescription": codex.get("shortDescription", ""),
        "longDescription": codex.get("longDescription", plugin["description"]),
        "developerName": AUTHOR["name"],
        "category": codex.get("category", "Developer Tools"),
        "capabilities": codex.get("capabilities", ["Interactive"]),
        "defaultPrompt": codex.get("defaultPrompt", []),
        "brandColor": codex.get("brandColor", "#0F766E"),
    }
    out[os.path.join(rel, ".codex-plugin", "plugin.json")] = dump_json({
        "name": plugin["name"],
        "version": plugin["version"],
        "description": plugin["description"],
        "author": AUTHOR,
        "keywords": plugin.get("keywords", []),
        "skills": "./skills/",
        "interface": interface,
    })
    for skill in plugin.get("skills", []):
        lines = [
            "interface:",
            "  display_name: " + yaml_str(skill["displayName"]),
            "  short_description: " + yaml_str(skill["shortDescription"]),
            "  default_prompt: " + yaml_str(skill["defaultPrompt"]),
        ]
        if skill["invocation"] == "user":
            lines += ["policy:", "  allow_implicit_invocation: false"]
        out[os.path.join(rel, "skills", skill["name"], "agents", "openai.yaml")] = "\n".join(lines) + "\n"
    out.update(render_plugin_agents(plugin["name"], rel, roster, root))
    return out


def render_plugin_agents(plugin_name, rel, roster, root):
    out = {}
    rendered = render_agents.render(roster, "roster/agents.json", os.path.join(root, "roster", "templates"), base=root, plugin=plugin_name)
    for (host, name), content in rendered.items():
        if host == "claude":
            out[os.path.join(rel, "agents", name + ".md")] = content
        else:
            out[os.path.join(rel, "codex-agents", name + ".toml")] = content
    return out


def render_marketplaces(plugins):
    claude_entries = []
    codex_entries = []
    for plugin in plugins:
        source = "./plugins/" + os.path.basename(plugin["_dir"])
        claude_entries.append({
            "name": plugin["name"],
            "source": source,
            "description": plugin["description"],
            "version": plugin["version"],
        })
        codex_entries.append({
            "name": plugin["name"],
            "source": {"source": "local", "path": source},
            "policy": {"installation": "AVAILABLE"},
            "category": plugin.get("codex", {}).get("category", "Developer Tools"),
        })
    return {
        os.path.join(".claude-plugin", "marketplace.json"): dump_json({
            "name": MARKETPLACE_NAME,
            "description": MARKETPLACE_DESCRIPTION,
            "owner": AUTHOR,
            "plugins": claude_entries,
        }),
        os.path.join(".agents", "plugins", "marketplace.json"): dump_json({
            "name": MARKETPLACE_NAME,
            "interface": {"displayName": "Brain Plugins"},
            "plugins": codex_entries,
        }),
    }


def render_all(root):
    roster = read_json(os.path.join(root, "roster", "agents.json"))
    plugins = load_plugins(root)
    out = {}
    for plugin in plugins:
        out.update(render_plugin(plugin, roster, root))
    out.update(render_marketplaces(plugins))
    standards = [p for p in plugins if p["name"] == "standards"]
    if standards:
        out.update(rules.render(root, standards[0]["version"]))
    for source in sorted(glob.glob(os.path.join(root, "shared", "sh", "*.sh"))):
        for target_dir in SHARED_SH_DIRS:
            out[os.path.join(target_dir, os.path.basename(source))] = read_text(source)
    for source in sorted(glob.glob(os.path.join(root, "roster", "templates", "*"))):
        out[os.path.join(AGENT_TEMPLATES_DIR, os.path.basename(source))] = read_text(source)
    out[os.path.join(AGENT_TEMPLATES_DIR, "defaults.json")] = dump_json({
        "_readme": "Roster defaults copied from the marketplace (roster/agents.json): the tiers and the Claude-to-Codex model map a project roster may leave out or override.",
        "model_map": roster["model_map"],
        "tiers": roster["tiers"],
    })
    return out


def generated_on_disk(root):
    """Generated files present on disk, so --check also catches stale leftovers."""
    patterns = [
        "plugins/*/.claude-plugin/plugin.json",
        "plugins/*/.codex-plugin/plugin.json",
        "plugins/*/skills/*/agents/openai.yaml",
        "plugins/*/agents/*.md",
        "plugins/*/codex-agents/*.toml",
        "plugins/standards/rules/*.md",
        "plugins/standards/rules/*.json",
        "plugins/standards/rules/common/*.md",
        "plugins/*/hooks/json.sh",
        "plugins/*/hooks/stamp.sh",
        "plugins/*/lib/json.sh",
        "plugins/*/lib/stamp.sh",
        "plugins/standards/templates/agents/*",
    ]
    found = set()
    for pattern in patterns:
        for path in glob.glob(os.path.join(root, pattern)):
            plugin_dir = path.split(os.sep + "plugins" + os.sep, 1)[1].split(os.sep)[0]
            if os.path.exists(os.path.join(root, "plugins", plugin_dir, "plugin.source.json")):
                found.add(os.path.relpath(path, root))
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    args = parser.parse_args()
    root = args.root
    rendered = render_all(root)
    if args.check:
        stale = []
        for rel, content in sorted(rendered.items()):
            path = os.path.join(root, rel)
            if not os.path.exists(path) or read_text(path) != content:
                stale.append(rel)
        for rel in sorted(generated_on_disk(root) - set(rendered)):
            stale.append(rel + " (leftover, not generated any more)")
        if stale:
            print("stale generated files, run tools/generate.sh:")
            for rel in stale:
                print("  " + rel)
            return 1
        print("generated files are fresh (%d)" % len(rendered))
        return 0
    for rel, content in sorted(rendered.items()):
        path = os.path.join(root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    for rel in sorted(generated_on_disk(root) - set(rendered)):
        os.remove(os.path.join(root, rel))
        print("removed " + rel)
    print("wrote %d files" % len(rendered))
    return 0


if __name__ == "__main__":
    sys.exit(main())

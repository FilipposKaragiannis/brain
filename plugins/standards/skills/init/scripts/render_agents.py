#!/usr/bin/env python3
"""Render a roster into the two hosts' agent files.

The marketplace generator uses it for the plugin rosters; `standards init` uses it for a project
roster (`project.roster` in .standards/config.json), so a project writes no renderer of its own.

    render_agents.py --roster AI/agents/roster.json --templates <dir> --out <dir>

Writes <out>/claude/<name>.md and <out>/codex/<name>.toml for every agent. Roster schema: see the
marketplace's roster/agents.json. `tiers` and `model_map` fall back to <templates>/defaults.json
when the roster has none. A brief defaults to <roster dir>/briefs/<name>.md. `skills` becomes the
Claude frontmatter list; `paths` stays in the roster for the review skill.
"""
import argparse
import json
import os
import sys


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def fill(template, fields):
    text = template
    for key, value in fields.items():
        text = text.replace("{{" + key + "}}", value)
    return text


def toml_multiline(text):
    return text.replace("\\", "\\\\").replace('"""', '\\"\\"\\"')


def render(roster, roster_path, templates_dir, base=".", plugin=None):
    """Return {("claude"|"codex", name): content} for the roster's agents (of one plugin when given)."""
    defaults_path = os.path.join(templates_dir, "defaults.json")
    defaults = json.loads(read_text(defaults_path)) if os.path.exists(defaults_path) else {}
    tiers = dict(defaults.get("tiers", {}), **roster.get("tiers", {}))
    model_map = dict(defaults.get("model_map", {}), **roster.get("model_map", {}))
    claude_tpl = read_text(os.path.join(templates_dir, "claude-agent.md"))
    codex_tpl = read_text(os.path.join(templates_dir, "codex-agent.toml"))
    out = {}
    for name, agent in sorted(roster["agents"].items()):
        if plugin and agent.get("plugin") != plugin:
            continue
        tier = tiers[agent["tier"]]
        brief_path = agent.get("brief") or os.path.join(os.path.dirname(roster_path), "briefs", name + ".md")
        brief = read_text(os.path.join(base, brief_path)).rstrip("\n")
        extra = ""
        tools = tier.get("claude_tools")
        if tools:
            extra += "tools: " + ", ".join(tools) + "\n"
        skills = agent.get("skills")
        if skills:
            extra += "skills:\n" + "".join("  - %s\n" % s for s in skills)
        fields = {
            "name": name,
            "description": agent["description"],
            "model": agent["model"],
            "effort": agent["effort"],
            "extra": extra,
            "codex_model": agent.get("codex_model") or model_map[agent["model"]],
            "sandbox_mode": tier["codex_sandbox"],
        }
        out[("claude", name)] = fill(claude_tpl, dict(fields, brief=brief))
        out[("codex", name)] = fill(codex_tpl, dict(fields, brief=toml_multiline(brief)))
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--roster", required=True)
    parser.add_argument("--templates", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    roster = json.loads(read_text(args.roster))
    rendered = render(roster, args.roster, args.templates)
    for (host, name), content in rendered.items():
        path = os.path.join(args.out, host, name + (".md" if host == "claude" else ".toml"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    print("rendered %d agent(s)" % (len(rendered) // 2))
    return 0


if __name__ == "__main__":
    sys.exit(main())

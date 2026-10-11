#!/usr/bin/env python3
"""Add a project's own agents to the brain map, from any repository.

The marketplace renders the map (tools/lib/map.py) and ships a copy as ../assets/map.html with
three empty markers. This script fills them from a project roster (project.roster in
.standards/config.json), so the map skill can show the "This project" group in a project that has
no marketplace checkout. The marketplace renderer imports the card helpers from here, so both
pages draw an agent the same way.

    project_map.py --roster AI/agents/roster.json --out <file> [--page <map.html>]
"""
import argparse
import html
import json
import os
import re
import sys

EFFORT_RANK = {"low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5}
MARK_COUNT = "<!--project-count-->"
MARK_LEGEND = "<!--project-legend-->"
MARK_GROUP = "<!--project-roster-->"
DEFAULT_PAGE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets", "map.html")


def esc(s):
    return html.escape(str(s), quote=True)


def trigger_of(description):
    """The 'when' of a skill or agent: the sentence that starts with 'Use when', shortened."""
    m = re.search(r"Use (?:it )?when (.*?)(?:\.|$)", description)
    if not m:
        return ""
    when = m.group(1).strip()
    when = re.sub(r"^(the user|a user|the owner|someone) (asks|wants|says|mentions|reports)( to| for| about)? ?", "", when)
    return when[0].upper() + when[1:] if when else ""


def agent_card(a, color, extra=""):
    bars = "".join('<i%s></i>' % (' class="on"' if i < EFFORT_RANK.get(a["effort"], 0) else "") for i in range(5))
    return ('<div class="agent%s" style="--pc:%s"><code>%s</code><div class="m"><span>%s</span><span class="bars" title="effort %s">%s</span><span>%s</span></div><div class="step">%s</div></div>'
            % (extra, esc(color), esc(a["name"]), esc(a["model"]), esc(a["effort"]), bars, esc(a["tier"]), esc(a["step"] or "")))


def load_roster(path):
    """The project's agents, from a roster JSON in the marketplace schema. Missing fields stay
    empty: a project roster is hand-written."""
    with open(path, encoding="utf-8") as f:
        roster = json.load(f)
    out = []
    for name, a in sorted(roster.get("agents", {}).items()):
        desc = a.get("description", "")
        out.append({"name": name, "model": a.get("model", ""), "effort": a.get("effort", ""),
                    "tier": a.get("tier", ""), "step": trigger_of(desc) or desc})
    return out


def inject(page, agents):
    """Fill the page's markers with the project's agents. A page without markers is refused."""
    if MARK_GROUP not in page:
        raise ValueError("the page has no %s marker; regenerate it with tools/generate.sh" % MARK_GROUP)
    if not agents:
        return page
    group = ('<h3 class="proj-head">This project (%d)</h3><div class="agents">%s</div>'
             % (len(agents), "".join(agent_card(a, "var(--fg)", " proj") for a in agents)))
    return (page.replace(MARK_COUNT, " (+%d yours)" % len(agents), 1)
                .replace(MARK_LEGEND, "<span>dashed: this project</span>", 1)
                .replace(MARK_GROUP, group, 1))


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--roster", required=True, help="the project's roster JSON")
    ap.add_argument("--out", required=True, help="where to write the page; keep it out of the repository")
    ap.add_argument("--page", default=DEFAULT_PAGE, help="the map to fill (default: the copy this plugin ships)")
    args = ap.parse_args()
    with open(args.page, encoding="utf-8") as f:
        page = f.read()
    try:
        filled = inject(page, load_roster(args.roster))
    except (OSError, ValueError, json.JSONDecodeError) as e:
        print("project_map: %s" % e, file=sys.stderr)
        return 1
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(filled)
    print("project_map: wrote %s" % args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Render the brain map: one page that shows every plugin, skill, agent and hook, the flow's
steps per profile and where the hooks intervene in a session. Read by tools/lib/generate.py,
which writes docs/map.html; the meta:map skill publishes that file. Everything on the page comes
from the sources (plugin.source.json, skills/*/SKILL.md, roster/agents.json, hooks/hooks.json,
flow/profiles.json), so the page can never say something the plugins do not."""
import glob
import html
import json
import os
import re

PLUGIN_ORDER = ["standards", "flow", "craft", "meta"]
MODEL_RANK = {"haiku": 1, "sonnet": 2, "opus": 3, "fable": 4}
# The brand colours are made for a light ground; these tints carry the same hue on a dark one.
DARK_TINT = {"standards": "#3FD1BE", "flow": "#8FB0FF", "craft": "#C9A8FF", "meta": "#F3B06A"}
EFFORT_RANK = {"low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5}


def read_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def frontmatter(path):
    text = open(path, encoding="utf-8").read()
    parts = text.split("---", 2)
    out = {}
    if len(parts) >= 3:
        for line in parts[1].splitlines():
            m = re.match(r"^([A-Za-z-]+):\s*(.*)$", line)
            if m:
                out[m.group(1)] = m.group(2).strip()
    return out


def trigger_of(description):
    """The 'when' of a skill: the sentence that starts with 'Use when', shortened."""
    m = re.search(r"Use (?:it )?when (.*?)(?:\.|$)", description)
    if not m:
        return ""
    when = m.group(1).strip()
    when = re.sub(r"^(the user|a user|the owner|someone) (asks|wants|says|mentions|reports)( to| for| about)? ?", "", when)
    return when[0].upper() + when[1:] if when else ""


def load(root):
    plugins = []
    for name in PLUGIN_ORDER:
        src = os.path.join(root, "plugins", name, "plugin.source.json")
        if not os.path.exists(src):
            continue
        p = read_json(src)
        manifest = {s["name"]: s for s in p.get("skills", [])}
        skills = []
        for path in sorted(glob.glob(os.path.join(root, "plugins", name, "skills", "*", "SKILL.md"))):
            fm = frontmatter(path)
            m = manifest.get(fm.get("name", ""), {})
            skills.append({
                "name": fm.get("name", os.path.basename(os.path.dirname(path))),
                "short": m.get("shortDescription", ""),
                "when": trigger_of(fm.get("description", "")),
                "auto": fm.get("disable-model-invocation", "") != "true",
            })
        hooks = []
        hooks_path = os.path.join(root, "plugins", name, "hooks", "hooks.json")
        if os.path.exists(hooks_path):
            for event, entries in read_json(hooks_path).get("hooks", {}).items():
                for e in entries:
                    for h in e.get("hooks", []):
                        label = h.get("statusMessage", "") or ""
                        label = re.sub(r"^[a-z]+: ", "", label)
                        hooks.append({"event": event, "matcher": e.get("matcher", ""), "label": label})
        plugins.append({
            "name": name, "version": p.get("version", ""),
            "short": p.get("codex", {}).get("shortDescription", ""),
            "color": p.get("codex", {}).get("brandColor", "#555555"),
            "dark": DARK_TINT.get(name, p.get("codex", {}).get("brandColor", "#AAAAAA")),
            "skills": skills, "hooks": hooks,
        })
    roster = read_json(os.path.join(root, "roster", "agents.json"))
    agents = []
    for aname, a in roster["agents"].items():
        agents.append({"name": aname, "plugin": a["plugin"], "step": a.get("step", ""), "model": a["model"],
                       "effort": a["effort"], "tier": a.get("tier", "")})
    profiles = read_json(os.path.join(root, "plugins", "flow", "profiles.json"))
    return plugins, agents, profiles


def merged_order(profiles, names):
    """One column order that keeps every profile's own order (the longest first)."""
    order = []
    for n in sorted(names, key=lambda n: -len(profiles[n])):
        steps = profiles[n]
        for i, s in enumerate(steps):
            if s in order:
                continue
            after = [t for t in steps[i + 1:] if t in order]
            if after:
                order.insert(order.index(after[0]), s)
            else:
                order.append(s)
    return order


def esc(s):
    return html.escape(str(s), quote=True)


def svg_pipeline(profiles_json, names, title):
    """Rows = profiles, columns = steps; a dot where the profile runs the step, a diamond for a
    gate, a line along the row. Under each column the agent or the skill that runs it."""
    profiles = profiles_json["profiles"]
    steps = profiles_json["steps"]
    order = merged_order(profiles, names)
    colw, left, top, rowh = 68, 92, 74, 34
    w = left + colw * len(order) + 16
    h = top + rowh * len(names) + 44
    out = ['<svg viewBox="0 0 %d %d" width="%d" role="img" aria-label="%s" xmlns="http://www.w3.org/2000/svg">' % (w, h, w, esc(title))]
    out.append('<style>text{font:11px var(--mono);fill:currentColor}.lbl{font:12px var(--body)}.sub{fill:var(--muted);font-size:10px}</style>')
    for i, s in enumerate(order):
        x = left + colw * i + colw / 2
        gate = s.startswith("gate:")
        label = s[5:] if gate else s
        out.append('<text x="%.0f" y="22" text-anchor="middle" class="lbl"%s>%s</text>' % (x, ' fill="var(--muted)"' if gate else "", esc(label)))
        if not gate:
            runner = steps.get(s, {}).get("agent") or ("flow:" + steps.get(s, {}).get("skill", "")) if s in steps else ""
            out.append('<text x="%.0f" y="40" text-anchor="middle" class="sub">%s</text>' % (x, esc(runner)))
        else:
            out.append('<text x="%.0f" y="40" text-anchor="middle" class="sub">you decide</text>' % x)
        out.append('<line x1="%.0f" y1="52" x2="%.0f" y2="%d" stroke="var(--line)" stroke-dasharray="2 4"/>' % (x, x, h - 36))
    for r, n in enumerate(names):
        y = top + rowh * r + rowh / 2
        xs = [left + colw * order.index(s) + colw / 2 for s in profiles[n]]
        out.append('<text x="%d" y="%.0f" dominant-baseline="middle" class="lbl">%s</text>' % (8, y, esc(n)))
        out.append('<line x1="%.0f" y1="%.0f" x2="%.0f" y2="%.0f" stroke="currentColor" stroke-width="1.5"/>' % (xs[0], y, xs[-1], y))
        for s, x in zip(profiles[n], xs):
            if s.startswith("gate:"):
                out.append('<rect x="%.1f" y="%.1f" width="11" height="11" transform="rotate(45 %.1f %.1f)" fill="var(--bg)" stroke="var(--accent)" stroke-width="2"/>' % (x - 5.5, y - 5.5, x, y))
            else:
                out.append('<circle cx="%.0f" cy="%.0f" r="6" fill="currentColor"/>' % (x, y))
    ly = h - 14
    out.append('<circle cx="%d" cy="%d" r="5" fill="currentColor"/><text x="%d" y="%d" dominant-baseline="middle" class="sub">a step, run by an agent in a fresh context</text>' % (left, ly, left + 12, ly))
    gx = left + 290
    out.append('<rect x="%.1f" y="%.1f" width="9" height="9" transform="rotate(45 %d %d)" fill="var(--bg)" stroke="var(--accent)" stroke-width="2"/><text x="%d" y="%d" dominant-baseline="middle" class="sub">a gate: the run stops and asks you</text>' % (gx - 4.5, ly - 4.5, gx, ly, gx + 12, ly))
    out.append("</svg>")
    return "\n".join(out)


def svg_session(plugins):
    """Where the hooks intervene: a session as a line with its events, and under each event the
    checks each plugin runs there, coloured by plugin."""
    events = [("SessionStart", "session starts"), ("PreToolUse", "each shell command"), ("WorktreeCreate", "a worktree is opened"),
              ("WorktreeRemove", "a worktree is closed"), ("SubagentStop", "an agent finishes"), ("Stop", "the session ends")]
    colw, left, top = 150, 20, 46
    rows = []
    for ev, _ in events:
        rows.append([("var(--c-%s)" % p["name"], h["label"]) for p in plugins for h in p["hooks"] if h["event"] == ev])
    depth = max(len(r) for r in rows)
    w = left + colw * len(events)
    h = top + 40 + 18 * depth + 10
    out = ['<svg viewBox="0 0 %d %d" width="%d" role="img" aria-label="Where the plugins intervene during a session" xmlns="http://www.w3.org/2000/svg">' % (w, h, w)]
    out.append('<style>text{font:11px var(--body);fill:currentColor}.sub{fill:var(--muted);font-size:10px}</style>')
    out.append('<defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>')
    out.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="currentColor" stroke-width="1.5" marker-end="url(#arr)"/>' % (left, top, w - 8, top))
    for i, (ev, label) in enumerate(events):
        x = left + colw * i + 16
        out.append('<circle cx="%d" cy="%d" r="5" fill="var(--bg)" stroke="currentColor" stroke-width="2"/>' % (x, top))
        out.append('<text x="%d" y="%d">%s</text>' % (x - 5, top - 14, esc(label)))
        for j, (color, text) in enumerate(rows[i]):
            y = top + 30 + 18 * j
            out.append('<circle cx="%d" cy="%d" r="4" fill="%s"/><text x="%d" y="%d" dominant-baseline="middle" class="sub">%s</text>' % (x, y, esc(color), x + 10, y, esc(text)))
    out.append("</svg>")
    return "\n".join(out)


def render_map(root):
    plugins, agents, profiles = load(root)
    by_plugin = {p["name"]: p for p in plugins}
    skill_count = sum(len(p["skills"]) for p in plugins)
    glyph_auto = '<svg class="g" viewBox="0 0 12 12" aria-hidden="true"><path d="M7 1 2 7h4l-1 4 5-6H6z" fill="currentColor"/></svg>'
    glyph_ask = '<svg class="g" viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="4.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M6 3.5v3M6 8.5v.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>'
    light = "".join("--c-%s:%s;" % (p["name"], p["color"]) for p in plugins)
    dark = "".join("--c-%s:%s;" % (p["name"], p["dark"]) for p in plugins)
    o = []
    o.append("<title>Brain Map</title>")
    o.append("""<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Atkinson+Hyperlegible:wght@400;700&family=JetBrains+Mono:wght@400;600&display=swap">
<style>
/* Layout: a plugin strip on top, then four figures (the flow, the session, the skills, the agents); every colour a token, each plugin keeps its brand hue. */
:root{--bg:#F3F5F7;--panel:#FFFFFF;--fg:#182029;--muted:#5E6B78;--line:#D3DAE2;--accent:#1D4ED8;LIGHT--body:"Atkinson Hyperlegible",system-ui,sans-serif;--mono:"JetBrains Mono",ui-monospace,Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0E1318;--panel:#161C23;--fg:#E4E9EF;--muted:#8E9AA7;--line:#2A333D;--accent:#7FA2FF;DARKcolor-scheme:dark}}
:root[data-theme="dark"]{--bg:#0E1318;--panel:#161C23;--fg:#E4E9EF;--muted:#8E9AA7;--line:#2A333D;--accent:#7FA2FF;DARKcolor-scheme:dark}
body{background:var(--bg);color:var(--fg);font-family:var(--body);font-size:15px;line-height:1.45;padding:0 16px;padding-block:28px 48px}
main{max-width:1080px;margin:0 auto;display:grid;gap:36px}
h1{font-size:26px;margin:0;letter-spacing:-.01em;text-wrap:balance}
h1 small{font-family:var(--mono);font-size:12px;color:var(--muted);margin-left:10px;font-weight:400}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);margin:0 0 12px;font-weight:700}
.plugins{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:12px}
.plugin{background:var(--panel);border:1px solid var(--line);border-left:5px solid var(--pc);border-radius:6px;padding:12px 14px;display:grid;gap:4px;min-width:0}
.plugin b{font-family:var(--mono);font-size:14px}.plugin b span{color:var(--muted);font-weight:400;margin-left:6px;font-size:12px}
.plugin .role{color:var(--muted);font-size:13px}
.plugin .n{font-family:var(--mono);font-size:11px;color:var(--muted);display:flex;gap:12px;font-variant-numeric:tabular-nums}
figure{margin:0;background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:14px 16px;min-width:0}
figure>div{overflow-x:auto}figure svg{display:block;max-width:100%;height:auto}
figcaption{color:var(--muted);font-size:13px;margin-top:8px}
.skills{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px}
.group{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:12px 14px;min-width:0}
.group h3{font-family:var(--mono);font-size:13px;margin:0 0 8px;color:var(--pc)}
.skill{display:grid;grid-template-columns:18px 1fr;gap:0 8px;padding:7px 0;border-top:1px solid var(--line);align-items:start}
.skill:first-of-type{border-top:0}
.skill code{font-family:var(--mono);font-size:13px;font-weight:600}
.skill .when{color:var(--muted);font-size:13px;grid-column:2}
.g{width:14px;height:14px;margin-top:3px;color:var(--pc)}
.legend{display:flex;gap:18px;flex-wrap:wrap;color:var(--muted);font-size:13px;align-items:center}.legend span{display:inline-flex;align-items:center;gap:6px}
.agents{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:8px}
.agent{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:9px 12px;display:grid;grid-template-columns:1fr auto;gap:2px 10px;align-items:center;min-width:0}
.agent code{font-family:var(--mono);font-size:13px;font-weight:600;color:var(--pc);overflow-wrap:anywhere}
.agent .step{color:var(--muted);font-size:12px;grid-column:1}
.agent .m{font-family:var(--mono);font-size:11px;color:var(--muted);grid-row:1/3;display:grid;justify-items:end;gap:3px;font-variant-numeric:tabular-nums}
.bars{display:inline-flex;gap:2px}.bars i{width:5px;height:9px;background:var(--line);border-radius:1px}.bars i.on{background:var(--pc)}
.tier{font-size:10px;letter-spacing:.04em;text-transform:uppercase}
.install{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:12px}
.install div{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:12px 14px;min-width:0}
.install b{display:block;font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);margin-bottom:6px}
pre{margin:0;font-family:var(--mono);font-size:12px;white-space:pre-wrap;overflow-wrap:anywhere;line-height:1.6}
a{color:var(--accent)}
@media (prefers-reduced-motion:no-preference){.agent,.plugin{transition:border-color .15s}}
</style>""".replace("LIGHT", light).replace("DARK", dark))
    o.append("<main>")
    o.append('<header><h1>Brain Map<small>%d plugins · %d skills · %d agents</small></h1></header>' % (len(plugins), skill_count, len(agents)))
    # plugins
    o.append('<section><h2>Plugins</h2><div class="plugins">')
    for p in plugins:
        n_agents = sum(1 for a in agents if a["plugin"] == p["name"])
        o.append('<div class="plugin" style="--pc:var(--c-%s)"><b>%s<span>v%s</span></b><div class="role">%s</div><div class="n"><span>%d skills</span><span>%d agents</span><span>%d hooks</span></div></div>'
                 % (esc(p["name"]), esc(p["name"]), esc(p["version"]), esc(p["short"]), len(p["skills"]), n_agents, len(p["hooks"])))
    o.append("</div></section>")
    # the flow
    o.append('<section><h2>The flow, by item kind and size</h2>')
    o.append('<figure><div>%s</div><figcaption>A task or a bug: the steps each profile runs, left to right. The size (S, M, L) picks the profile; a P0 in review or a failed verify sends the item back to implement.</figcaption></figure>'
             % svg_pipeline(profiles, ["bugfix", "task-S", "task-M", "task-L"], "The steps a task or bug runs, per profile"))
    o.append('<figure style="margin-top:12px"><div>%s</div><figcaption>An epic: interview, epic body, decomposition into tasks, then closeout once every task is merged.</figcaption></figure>'
             % svg_pipeline(profiles, ["epic"], "The steps an epic runs"))
    o.append("</section>")
    # session
    o.append('<section><h2>Where the plugins step in</h2><figure><div>%s</div><figcaption>Hooks run on both hosts from the plugin itself. The dots take the plugin\'s colour.</figcaption></figure></section>' % svg_session(plugins))
    # skills
    o.append('<section><h2>Skills</h2><div class="legend"><span>%s runs on its own when the ask matches</span><span>%s runs when you call it</span></div><div class="skills" style="margin-top:10px">' % (glyph_auto.replace('class="g"', 'class="g" style="color:var(--fg)"'), glyph_ask.replace('class="g"', 'class="g" style="color:var(--fg)"')))
    for p in plugins:
        o.append('<div class="group" style="--pc:var(--c-%s)"><h3>%s</h3>' % (esc(p["name"]), esc(p["name"])))
        for s in p["skills"]:
            o.append('<div class="skill">%s<code>%s</code><div class="when">%s</div></div>'
                     % (glyph_auto if s["auto"] else glyph_ask, esc(s["name"]), esc(s["when"] or s["short"])))
        o.append("</div>")
    o.append("</div></section>")
    # agents
    o.append('<section><h2>Agents</h2><div class="legend"><span>bars: effort</span><span>name colour: plugin</span><span>tier: what it may touch</span></div><div class="agents" style="margin-top:10px">')
    for a in sorted(agents, key=lambda a: (PLUGIN_ORDER.index(a["plugin"]) if a["plugin"] in PLUGIN_ORDER else 9, a["name"])):
        color = "var(--c-%s)" % a["plugin"] if a["plugin"] in by_plugin else "var(--muted)"
        bars = "".join('<i%s></i>' % (' class="on"' if i < EFFORT_RANK.get(a["effort"], 0) else "") for i in range(5))
        o.append('<div class="agent" style="--pc:%s"><code>%s</code><div class="m"><span>%s</span><span class="bars" title="effort %s">%s</span><span class="tier">%s</span></div><div class="step">%s</div></div>'
                 % (esc(color), esc(a["name"]), esc(a["model"]), esc(a["effort"]), bars, esc(a["tier"]), esc(a["step"] or "")))
    o.append("</div></section>")
    # install
    o.append('<section><h2>Install</h2><div class="install">')
    o.append('<div><b>Claude</b><pre>claude plugin marketplace add FilipposKaragiannis/brain\nclaude plugin install &lt;plugin&gt;@brain-plugins --scope project\n/standards:init · /flow:init</pre></div>')
    o.append('<div><b>Codex</b><pre>codex plugin marketplace add FilipposKaragiannis/brain\ncodex plugin add &lt;plugin&gt;@brain-plugins\n[plugins."&lt;plugin&gt;@brain-plugins"] enabled = true in .codex/config.toml\n/hooks once to trust the plugin hooks · $init</pre></div>')
    o.append("</div></section>")
    o.append("</main>")
    return "\n".join(o) + "\n"


if __name__ == "__main__":
    import sys
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    sys.stdout.write(render_map(root))

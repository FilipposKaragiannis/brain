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
import sys

from playbooks import EXTRAS, PLAYBOOKS  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugins", "meta", "skills", "map", "scripts"))
from project_map import EFFORT_RANK, MARK_COUNT, MARK_GROUP, MARK_LEGEND, agent_card, inject, load_roster, trigger_of  # noqa: E402,F401  (the plugin ships them)

PLUGIN_ORDER = ["standards", "flow", "craft", "meta", "console"]
MODEL_RANK = {"haiku": 1, "sonnet": 2, "opus": 3, "fable": 4}
# The brand colours are made for a light ground; these tints carry the same hue on a dark one.
DARK_TINT = {"standards": "#F2F2F2", "flow": "#C4C4C4", "craft": "#8E8E8E", "meta": "#5E5E5E", "console": "#3A3A3A"}
LIGHT_TINT = {"standards": "#0E0E0E", "flow": "#4D4D4D", "craft": "#808080", "meta": "#ABABAB", "console": "#C8C8C8"}
# One colour per flow profile, light and dark ground. Used by the transit map and the playbooks.
LINES = {"bugfix": ("#0E0E0E", "#F2F2F2"), "task-S": ("#4D4D4D", "#C4C4C4"), "task-M": ("#808080", "#8E8E8E"),
         "task-L": ("#ABABAB", "#5E5E5E"), "epic": ("#2B2B2B", "#DADADA")}
LINE_LABEL = {"bugfix": "bug", "task-S": "task S", "task-M": "task M", "task-L": "task L / XL", "epic": "epic"}


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
            "color": LIGHT_TINT.get(name, "#555555"),
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


def runner_of(steps, s):
    st = steps.get(s, {})
    return (st.get("agent") or "", st.get("skill") or "")


def metro(pj, keys, title):
    """A transit map. One coloured line per profile, one station per step; steps that several
    lines share are one interchange. Gates are diamonds: the run stops there and asks you."""
    profiles, steps = pj["profiles"], pj["steps"]
    order = merged_order(profiles, keys)
    colw, left, top, rowh, right = 78, 104, 104, 48, 80
    w = left + colw * len(order) + right
    h = top + rowh * len(keys) + 70
    cx = lambda i: left + colw * i + colw / 2
    ry = lambda r: top + rowh * r + rowh / 2
    o = ['<svg viewBox="0 0 %d %d" width="%d" role="img" aria-label="%s" xmlns="http://www.w3.org/2000/svg">' % (w, h, w, esc(title))]
    o.append('<style>text{font:11px var(--mono);fill:currentColor}.rl{font:700 13px var(--body)}.lbl{font:600 11px var(--mono)}.gt{fill:currentColor;font-weight:700}.sub{fill:var(--muted);font-size:10px}</style>')
    for i, s in enumerate(order):
        x = cx(i)
        gate = s.startswith("gate:")
        o.append('<line x1="%.0f" y1="%d" x2="%.0f" y2="%d" stroke="var(--line)" stroke-dasharray="2 5"/>' % (x, top - 6, x, h - 52))
        o.append('<text transform="translate(%.0f %d) rotate(-38)" class="lbl%s">%s</text>' % (x - 3, top - 14, " gt" if gate else "", esc(s[5:] if gate else s)))
        if gate:
            o.append('<text x="%.0f" y="%d" text-anchor="middle" class="sub gt">you</text>' % (x, h - 36))
        else:
            agent, skill = runner_of(steps, s)
            o.append('<text x="%.0f" y="%d" text-anchor="middle" class="sub"%s>%s</text>' % (x, h - 36, "" if agent else ' font-style="italic"', esc(agent or skill)))
    for i, s in enumerate(order):
        rows = [r for r, k in enumerate(keys) if s in profiles[k]]
        if len(rows) > 1:
            y0, y1 = ry(min(rows)), ry(max(rows))
            o.append('<rect x="%.1f" y="%.1f" width="20" height="%.1f" rx="10" fill="var(--panel)" stroke="var(--fg)" stroke-width="2"/>' % (cx(i) - 10, y0 - 12, y1 - y0 + 24))
    for r, k in enumerate(keys):
        y = ry(r)
        xs = [cx(order.index(s)) for s in profiles[k]]
        o.append('<g class="ln" data-line="%s">' % esc(k))
        o.append('<text x="6" y="%.0f" dominant-baseline="middle" class="rl">%s</text>' % (y, esc(LINE_LABEL.get(k, k))))
        o.append('<line x1="%.0f" y1="%.0f" x2="%.0f" y2="%.0f" stroke="var(--l-%s)" stroke-width="7" stroke-linecap="round"/>' % (xs[0], y, xs[-1], y, esc(k)))
        for s, x in zip(profiles[k], xs):
            if s.startswith("gate:"):
                o.append('<path d="M%.0f %.0f l10 10 l-10 10 l-10 -10 z" fill="var(--fg)" stroke="var(--panel)" stroke-width="2.5"/>' % (x, y - 10))
            else:
                o.append('<circle cx="%.0f" cy="%.0f" r="6.5" fill="var(--panel)" stroke="var(--l-%s)" stroke-width="3.5"/>' % (x, y, esc(k)))
        o.append("</g>")
    ly = h - 12
    o.append('<circle cx="%d" cy="%d" r="5" fill="var(--panel)" stroke="currentColor" stroke-width="3"/><text x="%d" y="%d" dominant-baseline="middle" class="sub">a step, run in a fresh context</text>' % (left, ly, left + 12, ly))
    gx = left + 220
    o.append('<path d="M%d %d l7 7 l-7 7 l-7 -7 z" fill="var(--fg)"/><text x="%d" y="%d" dominant-baseline="middle" class="sub">a gate: the run stops and asks you</text>' % (gx, ly - 7, gx + 12, ly))
    if w > 900:
        o.append('<text x="%d" y="%d" dominant-baseline="middle" class="sub">agent name, or <tspan font-style="italic">skill</tspan> when it spawns several</text>' % (gx + 220, ly))
    o.append("</svg>")
    return "\n".join(o)


def svg_session(plugins):
    """Where the hooks intervene: a session as a line with its events, and under each event the
    checks each plugin runs there, coloured by plugin."""
    events = [("SessionStart", "session starts"), ("PreToolUse", "each shell command"), ("WorktreeCreate", "worktree opened"),
              ("WorktreeRemove", "worktree closed"), ("SubagentStop", "an agent finishes"), ("Stop", "session ends")]
    colw, left, top = 168, 20, 46
    rows = []
    for ev, _ in events:
        rows.append([("var(--c-%s)" % p["name"], h["label"]) for p in plugins for h in p["hooks"] if h["event"] == ev])
    depth = max(len(r) for r in rows)
    w = left + colw * len(events)
    h = top + 40 + 18 * depth + 10
    out = ['<svg viewBox="0 0 %d %d" width="%d" role="img" aria-label="Where the plugins intervene during a session" xmlns="http://www.w3.org/2000/svg">' % (w, h, w)]
    out.append('<style>text{font:12px var(--body);fill:currentColor}.sub{fill:var(--muted);font-size:10.5px}</style>')
    out.append('<defs><marker id="arr" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="8" markerHeight="8" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker></defs>')
    out.append('<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="currentColor" stroke-width="2" marker-end="url(#arr)"/>' % (left, top, w - 8, top))
    for i, (ev, label) in enumerate(events):
        x = left + colw * i + 16
        out.append('<circle cx="%d" cy="%d" r="6" fill="var(--panel)" stroke="currentColor" stroke-width="2.5"/>' % (x, top))
        out.append('<text x="%d" y="%d" font-weight="700">%s</text>' % (x - 5, top - 16, esc(label)))
        for j, (color, text) in enumerate(rows[i]):
            y = top + 30 + 18 * j
            out.append('<circle cx="%d" cy="%d" r="4" fill="%s"/><text x="%d" y="%d" dominant-baseline="middle" class="sub">%s</text>' % (x, y, esc(color), x + 10, y, esc(text)))
    out.append("</svg>")
    return "\n".join(out)


def cmd_text(spec, host):
    """The command as typed: Claude /plugin:skill args, Codex $skill args."""
    name, args = spec
    skill = name.split(":", 1)[1]
    return ("/%s" % name if host == "claude" else "$%s" % skill) + ((" " + args) if args else "")


def cmd_html(spec, ask=""):
    return ('<span class="c-claude">%s</span><span class="c-codex">%s</span><span class="c-say">%s</span>'
            % (esc(cmd_text(spec, "claude")), esc(cmd_text(spec, "codex")), esc(ask or cmd_text(spec, "claude"))))


def sh_html(command, ask=""):
    """A shell step: the command with {host} filled per host; Plain words shows what to say to flow:do."""
    return ('<span class="c-claude">%s</span><span class="c-codex">%s</span><span class="c-say">%s</span>'
            % (esc(command.replace("{host}", "claude")), esc(command.replace("{host}", "codex")), esc(ask or command.replace("{host}", "claude"))))


def playbook_html(pb, pj, agents_by_name):
    key = pb["line"]
    strip = []
    for s in pj["profiles"][key]:
        strip.append('<li class="gate">%s</li>' % esc(s[5:]) if s.startswith("gate:") else "<li>%s</li>" % esc(s))
    out = ['<article class="pb" id="pb-%s" style="--lc:var(--l-%s)">' % (esc(pb["id"]), esc(key))]
    out.append('<header><h3>%s</h3><p>%s</p><ol class="strip" aria-label="the steps of this line">%s</ol></header>' % (esc(pb["title"]), esc(pb["lede"]), "".join(strip)))
    out.append('<ol class="steps">')
    for n, st in enumerate(pb["steps"], 1):
        cls = "gateful" if st.get("stop") else ""
        out.append('<li class="%s"><span class="n">%d</span><div class="b">' % (cls, n))
        if st.get("cmd"):
            out.append('<div class="cmd"><span class="p" aria-hidden="true">&rsaquo;</span><code>%s</code><button type="button" class="cp" aria-label="Copy the command">copy</button></div>' % cmd_html(st["cmd"], st.get("ask", "")))
        if st.get("sh"):
            out.append('<div class="cmd sh"><span class="p" aria-hidden="true">$</span><code>%s</code><button type="button" class="cp" aria-label="Copy the command">copy</button></div>' % sh_html(st["sh"], st.get("ask", "")))
        if st.get("act"):
            out.append('<div class="act">%s</div>' % esc(st["act"]))
        out.append('<p class="say">%s</p>' % esc(st["say"]))
        meta = []
        for a in st.get("who", []):
            meta.append('<span class="ag" style="--pc:var(--c-%s)">%s</span>' % (esc(agents_by_name.get(a, "flow")), esc(a)))
        if st.get("out"):
            meta.append('<span class="out">&rarr; %s</span>' % esc(st["out"]))
        if meta:
            out.append('<div class="meta">%s</div>' % "".join(meta))
        if st.get("stop"):
            out.append('<div class="stop"><b>%s</b><span>%s</span></div>' % (esc(st["stop"][0]), esc(st["stop"][1])))
        out.append("</div></li>")
    out.append("</ol></article>")
    return "\n".join(out)


CSS = """
/* Monochrome: black, white and greys with gradients. Lines and plugins differ by shade and by label. Every colour is a token. */
:root{--bg:#F3F3F2;--panel:#FFFFFF;--fg:#0E0E0E;--muted:#666666;--line:#D9D9D9;--accent:#0E0E0E;--glow:#FFFFFF;--tint:#EDEDED;--term:#121212;--term-fg:#F2F2F2;--term-dim:#8C8C8C;--term-hot:#D0D0D0;LIGHT--display:"Fraunces",Georgia,serif;--body:"Hanken Grotesk",system-ui,sans-serif;--mono:"JetBrains Mono",ui-monospace,Menlo,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#0A0A0A;--panel:#151515;--fg:#F2F2F2;--muted:#9A9A9A;--line:#2B2B2B;--accent:#F2F2F2;--glow:#242424;--tint:#1E1E1E;--term:#000000;DARKcolor-scheme:dark}}
:root[data-theme="dark"]{--bg:#0A0A0A;--panel:#151515;--fg:#F2F2F2;--muted:#9A9A9A;--line:#2B2B2B;--accent:#F2F2F2;--glow:#242424;--tint:#1E1E1E;--term:#000000;DARKcolor-scheme:dark}
*{box-sizing:border-box}
body{background:var(--bg);color:var(--fg);font-family:var(--body);font-size:16px;line-height:1.5;padding:0 16px;padding-block:0 72px;background-image:radial-gradient(ellipse 80% 420px at 50% 0,var(--glow),transparent 70%)}
main{max-width:1120px;margin:0 auto;display:grid;grid-template-columns:minmax(0,1fr);gap:72px}
main>*,.stack>*,figure{min-width:0}
.hero{padding-block:56px 8px;display:grid;gap:26px}
.hero h1{font:500 clamp(54px,11vw,120px)/.9 var(--display);letter-spacing:-.03em;margin:0;text-wrap:balance}
.hero h1 em{font-style:italic;font-weight:500;background:linear-gradient(100deg,var(--fg) 10%,var(--muted) 95%);-webkit-background-clip:text;background-clip:text;color:transparent}
.hero p{max-width:46ch;margin:0;font-size:19px;color:var(--muted);text-wrap:balance}
.stats{display:flex;flex-wrap:wrap;gap:12px 40px}
.stats div{display:grid}.stats b{font:500 44px/1 var(--display);font-variant-numeric:tabular-nums}.stats span{font:600 11px var(--mono);text-transform:uppercase;letter-spacing:.1em;color:var(--muted)}
nav.jump{display:flex;flex-wrap:wrap;gap:8px}
nav.jump a{background:var(--panel);font:600 12px var(--mono);text-decoration:none;color:var(--fg);border:1.5px solid var(--fg);border-radius:99px;padding:5px 13px}
nav.jump a:hover{background:var(--fg);color:var(--bg)}
section>h2{font:500 clamp(30px,5vw,44px)/1 var(--display);letter-spacing:-.02em;margin:0 0 6px;display:flex;align-items:baseline;gap:14px}
section>h2 i{font:600 12px var(--mono);color:var(--accent);letter-spacing:.08em;font-style:normal}
.sub{color:var(--muted);margin:0 0 22px;max-width:60ch}
.plugins{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:16px}
.plugin{background:linear-gradient(155deg,var(--panel) 40%,var(--tint));border:2px solid var(--fg);border-radius:14px;padding:18px 18px 16px;display:grid;gap:10px;min-width:0;position:relative;overflow:hidden;box-shadow:5px 5px 0 var(--pc)}
.plugin h3{font:500 30px/1 var(--display);margin:0;color:var(--fg);display:flex;justify-content:space-between;align-items:baseline;gap:8px;letter-spacing:-.02em}
.plugin h3 small{font:600 11px var(--mono);color:var(--muted);letter-spacing:0}
.plugin p{margin:0;color:var(--muted);font-size:14px}
.dots{display:flex;flex-wrap:wrap;gap:5px;align-items:center}
.dots i{display:block;width:12px;height:12px;background:var(--pc)}
.dots .ds{border-radius:50%}.dots .da{border-radius:2px}.dots .dh{width:0;height:0;background:none;border:7px solid transparent;border-bottom:12px solid var(--pc);border-top:0;border-left-width:6px;border-right-width:6px}
.key{display:flex;gap:12px;font:600 11px var(--mono);color:var(--muted);flex-wrap:wrap}
.key span{display:inline-flex;align-items:center;gap:5px}
.key i{display:inline-block;width:10px;height:10px;background:var(--fg)}
.key .ds{border-radius:50%}.key .da{border-radius:2px}.key .dh{width:0;height:0;background:none;border:6px solid transparent;border-bottom:10px solid var(--fg);border-top:0;border-left-width:5px;border-right-width:5px}
figure{margin:0;background:linear-gradient(180deg,var(--panel),var(--tint));border:2px solid var(--fg);border-radius:14px;padding:16px 18px;min-width:0}
figure>div{overflow-x:auto}figure svg{display:block;max-width:none;height:auto}
figcaption{color:var(--muted);font-size:14px;margin-top:10px}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 12px}
.chips button{font:600 12px var(--mono);border:2px solid var(--fg);border-left-width:10px;border-left-color:var(--lc);color:var(--fg);background:var(--panel);border-radius:99px;padding:4px 12px;cursor:pointer}
.chips button[aria-pressed="true"]{background:var(--fg);color:var(--bg)}
.ln{transition:opacity .2s}.dim{opacity:.18}
.stack{display:grid;gap:16px}
.bar{display:flex;flex-wrap:wrap;gap:12px 24px;align-items:center;justify-content:space-between;margin-bottom:16px}
.seg{display:none;border:2px solid var(--fg);border-radius:99px;overflow:hidden}
.js .seg{display:inline-flex}
.seg button{font:600 12px var(--mono);border:0;background:var(--panel);color:var(--fg);padding:6px 16px;cursor:pointer}
.seg button[aria-pressed="true"]{background:var(--fg);color:var(--bg)}
.tabs{display:none;flex-wrap:wrap;gap:8px}
.js .tabs{display:flex}
.tabs button{font:600 14px var(--body);border:2px solid var(--fg);background:var(--panel);color:var(--fg);border-radius:10px;padding:8px 14px;cursor:pointer;display:inline-flex;gap:8px;align-items:center}
.tabs button::before{content:"";width:12px;height:12px;border-radius:50%;background:var(--lc)}
.tabs button[aria-selected="true"]{background:var(--fg);color:var(--bg)}
.js .pb{display:none}.js .pb.on{display:block}
.pb{background:linear-gradient(180deg,var(--panel) 70%,var(--tint));border:2px solid var(--fg);border-radius:14px;padding:22px clamp(14px,3vw,28px) 10px;box-shadow:6px 6px 0 var(--lc);margin-bottom:22px}
.pb header h3{font:500 clamp(24px,4vw,32px)/1.1 var(--display);margin:0;letter-spacing:-.01em}
.pb header p{margin:4px 0 12px;color:var(--muted)}
.strip{list-style:none;padding:0;margin:0 0 18px;display:flex;flex-wrap:wrap;gap:4px 6px}
.strip li{font:600 11px var(--mono);padding:2px 9px;border-radius:99px;border:1.5px solid var(--lc);color:var(--fg)}
.strip li.gate{background:var(--fg);color:var(--bg);border-color:var(--fg);padding:1px 9px 1px 7px}
.strip li.gate::before{content:"\\25C6  "}
.steps{list-style:none;margin:0;padding:0;counter-reset:s}
.steps>li{display:grid;grid-template-columns:34px 1fr;gap:0 14px;position:relative;padding-bottom:20px}
.steps>li::before{content:"";position:absolute;left:16px;top:34px;bottom:0;width:2px;background:var(--lc);opacity:.5}
.steps>li:last-child::before{display:none}
.steps .n{width:34px;height:34px;border-radius:50%;background:var(--panel);border:3px solid var(--lc);display:grid;place-items:center;font:700 14px var(--mono);z-index:1}
.steps .gateful .n{border-radius:8px;transform:rotate(45deg);width:30px;height:30px;margin:2px;border-color:var(--fg);background:var(--fg)}
.steps .gateful .n{font-size:0}
.b{min-width:0;display:grid;gap:7px;padding-top:2px}
.cmd{display:flex;align-items:center;gap:10px;background:linear-gradient(100deg,var(--term),#2A2A2A);color:var(--term-fg);border-radius:9px;padding:9px 10px 9px 14px;font:500 14px var(--mono);min-width:0}
.cmd .p{color:var(--term-hot)}
.cmd code{flex:1;min-width:0;overflow-wrap:anywhere;font:inherit;user-select:all}
.cp{font:600 11px var(--mono);border:1px solid var(--term-dim);background:none;color:var(--term-dim);border-radius:6px;padding:2px 8px;cursor:pointer;display:none}
.js .cp{display:block}.cp:hover{color:var(--term-fg);border-color:var(--term-fg)}
.c-codex,.c-say{display:none}body[data-host="codex"] .c-claude,body[data-host="say"] .c-claude{display:none}body[data-host="codex"] .c-codex,body[data-host="say"] .c-say{display:inline}
.act{font-weight:700}
.say{margin:0;max-width:64ch}
.meta{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
.ag{font:600 11px var(--mono);color:var(--fg);border:1.5px solid var(--pc);border-left-width:6px;border-radius:6px;padding:1px 7px}
.out{font:600 12px var(--mono);color:var(--muted)}
.stop{display:grid;grid-template-columns:auto 1fr;gap:2px 12px;border-left:4px solid var(--fg);background:linear-gradient(90deg,var(--tint),transparent);border-radius:0 8px 8px 0;padding:8px 12px;align-items:baseline}
.stop b{font:700 12px var(--mono);color:var(--fg);text-transform:uppercase;letter-spacing:.06em}
.stop b::before{content:"\\25C6  "}
.also{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:10px}
.also div{display:grid;gap:6px}.also p{margin:0;color:var(--muted);font-size:14px}
.skills{display:grid;grid-template-columns:repeat(auto-fit,minmax(270px,1fr));gap:16px}
.group{background:var(--panel);border:2px solid var(--fg);border-radius:14px;padding:14px 16px;min-width:0}
.group h3{font:500 24px/1 var(--display);margin:0 0 8px;color:var(--fg);padding-left:10px;border-left:8px solid var(--pc)}
.skill{display:grid;grid-template-columns:18px 1fr;gap:0 8px;padding:8px 0;border-top:1px solid var(--line);align-items:start}
.skill:first-of-type{border-top:0}
.skill code{font:600 13px var(--mono)}
.skill .when{color:var(--muted);font-size:14px;grid-column:2}
.g{width:14px;height:14px;margin-top:3px;color:var(--fg)}
.legend{display:flex;gap:18px;flex-wrap:wrap;color:var(--muted);font-size:14px;align-items:center;margin-bottom:12px}.legend span{display:inline-flex;align-items:center;gap:6px}
.agents{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:10px}
.agent{background:var(--panel);border:1.5px solid var(--line);border-left:6px solid var(--pc);border-radius:8px;padding:9px 12px;display:grid;grid-template-columns:1fr auto;gap:2px 10px;align-items:center;min-width:0}
.agent code{font:600 13px var(--mono);overflow-wrap:anywhere}
.agent .step{color:var(--muted);font-size:13px}
.agent.proj{border-style:dashed;border-left-style:solid;border-left-color:var(--fg)}
.proj-head{font:700 12px var(--mono);text-transform:uppercase;letter-spacing:.08em;margin:22px 0 10px}
.agent .m{font:600 11px var(--mono);color:var(--muted);grid-row:1/3;grid-column:2;display:grid;justify-items:end;gap:3px}
.bars{display:inline-flex;gap:2px}.bars i{width:5px;height:10px;background:var(--line);border-radius:1px}.bars i.on{background:var(--pc)}
.install{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:16px}
.install div{background:linear-gradient(135deg,var(--term),#262626);color:var(--term-fg);border-radius:14px;padding:16px 18px;min-width:0}
.install b{display:block;font:700 11px var(--mono);text-transform:uppercase;letter-spacing:.1em;color:var(--term-hot);margin-bottom:8px}
pre{margin:0;font:13px/1.7 var(--mono);white-space:pre-wrap;overflow-wrap:anywhere}
a{color:var(--accent)}
:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
@media (prefers-reduced-motion:reduce){.ln{transition:none}}
"""

JS = """
(function(){
var d=document,r=d.documentElement;r.classList.add('js');
function all(s,c){return Array.prototype.slice.call((c||d).querySelectorAll(s));}
function store(k,v){try{if(v===undefined)return localStorage.getItem(k);localStorage.setItem(k,v);}catch(e){return null;}}
function setHost(h){d.body.setAttribute('data-host',h);all('.seg button').forEach(function(b){b.setAttribute('aria-pressed',String(b.getAttribute('data-host')===h));});}
all('.seg button').forEach(function(b){b.addEventListener('click',function(){var h=b.getAttribute('data-host');setHost(h);store('brain-host',h);});});
var h0=store('brain-host');setHost(h0==='codex'||h0==='say'?h0:'claude');
function showPb(id){all('.pb').forEach(function(p){p.classList.toggle('on',p.id==='pb-'+id);});all('.tabs button').forEach(function(t){t.setAttribute('aria-selected',String(t.getAttribute('data-pb')===id));});}
all('.tabs button').forEach(function(t){t.addEventListener('click',function(){showPb(t.getAttribute('data-pb'));});});
var first=all('.tabs button')[0];var want=(location.hash||'').replace('#pb-','');
showPb(all('.tabs button').some(function(t){return t.getAttribute('data-pb')===want;})?want:first.getAttribute('data-pb'));
all('.cp').forEach(function(b){b.addEventListener('click',function(){
  var c=b.parentNode.querySelector('.c-'+d.body.getAttribute('data-host'));var t=c.textContent;
  var done=function(){b.textContent='copied';setTimeout(function(){b.textContent='copy';},1200);};
  var sel=function(){var g=d.createRange();g.selectNodeContents(c);var s=getSelection();s.removeAllRanges();s.addRange(g);};
  if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(t).then(done,sel);}else{sel();}
});});
all('.chips').forEach(function(box){
  var svg=box.nextElementSibling.querySelector('svg');var cur=null;
  all('button',box).forEach(function(b){b.addEventListener('click',function(){
    var k=b.getAttribute('data-line');cur=(cur===k)?null:k;
    all('button',box).forEach(function(x){x.setAttribute('aria-pressed',String(x.getAttribute('data-line')===cur));});
    all('.ln',svg).forEach(function(g){g.classList.toggle('dim',cur!==null&&g.getAttribute('data-line')!==cur);});
  });});
});
})();
"""


def chips_html(keys):
    return '<div class="chips" aria-label="Highlight one line">%s</div>' % "".join(
        '<button type="button" data-line="%s" aria-pressed="false" style="--lc:var(--l-%s)">%s</button>' % (esc(k), esc(k), esc(LINE_LABEL.get(k, k))) for k in keys)


def render_map(root, project_roster=None):
    """project_roster: path to a project's roster JSON. The page then shows those agents beside
    the plugin agents. The committed docs/map.html is rendered without one."""
    plugins, agents, profiles = load(root)
    by_plugin = {p["name"]: p for p in plugins}
    agent_plugin = {a["name"]: a["plugin"] for a in agents}
    skill_count = sum(len(p["skills"]) for p in plugins)
    hook_count = sum(len(p["hooks"]) for p in plugins)
    glyph_auto = '<svg class="g" viewBox="0 0 12 12" aria-hidden="true"><path d="M7 1 2 7h4l-1 4 5-6H6z" fill="currentColor"/></svg>'
    glyph_ask = '<svg class="g" viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="4.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M6 3.5v3M6 8.5v.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>'
    light = "".join("--c-%s:%s;" % (p["name"], p["color"]) for p in plugins) + "".join("--l-%s:%s;" % (k, v[0]) for k, v in LINES.items())
    dark = "".join("--c-%s:%s;" % (p["name"], p["dark"]) for p in plugins) + "".join("--l-%s:%s;" % (k, v[1]) for k, v in LINES.items())
    o = []
    o.append("<title>Brain Map</title>")
    o.append('<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,500;9..144,700&family=Hanken+Grotesk:wght@400;500;700&family=JetBrains+Mono:wght@400;600;700&display=swap">')
    o.append("<style>%s</style>" % CSS.replace("LIGHT", light).replace("DARK", dark))
    o.append("<main>")
    o.append('<header class="hero"><h1>The <em>brain</em>,<br>mapped.</h1><p>Plugins for Claude Code and Codex that file the work, plan it, build it, check it and open the PR.</p>')
    o.append('<div class="stats"><div><b>%d</b><span>plugins</span></div><div><b>%d</b><span>skills</span></div><div><b>%d</b><span>agents</span></div><div><b>%d</b><span>hooks</span></div></div>'
             % (len(plugins), skill_count, len(agents), hook_count))
    o[-1] = o[-1].replace("<span>agents</span></div>", "<span>agents%s</span></div>" % MARK_COUNT, 1)
    o.append('<nav class="jump"><a href="#flows">Flows</a><a href="#playbooks">Playbooks</a><a href="#hooks">Hooks</a><a href="#skills">Skills</a><a href="#agents">Agents</a><a href="#install">Install</a></nav></header>')
    # plugins
    o.append('<section id="plugins"><div class="key"><span><i class="ds"></i>skill</span><span><i class="da"></i>agent</span><span><i class="dh"></i>hook</span></div><div class="plugins" style="margin-top:12px">')
    for p in plugins:
        n_agents = sum(1 for a in agents if a["plugin"] == p["name"])
        dots = '<i class="ds"></i>' * len(p["skills"]) + '<i class="da"></i>' * n_agents + '<i class="dh"></i>' * len(p["hooks"])
        o.append('<div class="plugin" style="--pc:var(--c-%s)"><h3>%s<small>v%s</small></h3><p>%s</p><div class="dots" aria-label="%d skills, %d agents, %d hooks">%s</div></div>'
                 % (esc(p["name"]), esc(p["name"]), esc(p["version"]), esc(p["short"]), len(p["skills"]), n_agents, len(p["hooks"]), dots))
    o.append("</div></section>")
    # flows
    task_keys = ["bugfix", "task-S", "task-M", "task-L"]
    o.append('<section id="flows"><h2><i>01</i>The flows</h2><p class="sub">You file an item. Its kind and size pick a line. The run follows the line and stops at every diamond.</p><div class="stack">')
    o.append('<div>%s<figure><div>%s</div><figcaption>Bugs and tasks. Where lines meet, they share a step. A failed review or verify sends the item back to implement.</figcaption></figure></div>'
             % (chips_html(task_keys), metro(profiles, task_keys, "The steps a bug or task runs, one line per profile")))
    o.append('<div>%s<figure><div>%s</div><figcaption>Epics. They produce tasks, then wait for every one to merge.</figcaption></figure></div>'
             % (chips_html(["epic"]), metro(profiles, ["epic"], "The steps an epic runs")))
    o.append("</div></section>")
    # playbooks
    o.append('<section id="playbooks"><h2><i>02</i>Playbooks</h2><p class="sub">Real sessions, step by step. Type what the dark box says, or switch to Plain words and say it. A $ box goes in a terminal or a scheduler. The diamond is where you answer.</p>')
    o.append('<div class="bar"><div class="tabs" role="tablist">%s</div><div class="seg" role="group" aria-label="Host"><button type="button" data-host="claude" aria-pressed="true">Claude</button><button type="button" data-host="codex" aria-pressed="false">Codex</button><button type="button" data-host="say" aria-pressed="false">Plain words</button></div></div>'
             % "".join('<button type="button" role="tab" data-pb="%s" aria-selected="false" style="--lc:var(--l-%s)">%s</button>' % (esc(pb["id"]), esc(pb["line"]), esc(pb["title"])) for pb in PLAYBOOKS))
    for pb in PLAYBOOKS:
        o.append(playbook_html(pb, profiles, agent_plugin))
    o.append('<h3 class="sub" style="font:700 12px var(--mono);text-transform:uppercase;letter-spacing:.08em;margin-top:30px">Also at hand</h3><div class="also">')
    for ex in EXTRAS:
        o.append('<div><div class="cmd"><span class="p" aria-hidden="true">&rsaquo;</span><code>%s</code></div><p>%s</p></div>' % (cmd_html(ex["cmd"], ex.get("ask", "")), esc(ex["say"])))
    o.append("</div></section>")
    # hooks
    o.append('<section id="hooks"><h2><i>03</i>Hooks</h2><p class="sub">Always on, no command needed. They stop mistakes while an agent works.</p><figure><div>%s</div><figcaption>Dots take the plugin\'s colour. Same hooks on both hosts.</figcaption></figure></section>' % svg_session(plugins))
    # skills
    o.append('<section id="skills"><h2><i>04</i>Skills</h2><div class="legend"><span>%s runs by itself when the ask fits</span><span>%s you call it</span></div><div class="skills">' % (glyph_auto.replace('class="g"', 'class="g" style="color:var(--fg)"'), glyph_ask.replace('class="g"', 'class="g" style="color:var(--fg)"')))
    for p in plugins:
        o.append('<div class="group" style="--pc:var(--c-%s)"><h3>%s</h3>' % (esc(p["name"]), esc(p["name"])))
        for s in p["skills"]:
            o.append('<div class="skill">%s<code>%s</code><div class="when">%s</div></div>'
                     % (glyph_auto if s["auto"] else glyph_ask, esc(s["name"]), esc(s["when"] or s["short"])))
        o.append("</div>")
    o.append("</div></section>")
    # agents
    o.append('<section id="agents"><h2><i>05</i>Agents</h2><div class="legend"><span>bars: effort</span><span>stripe: plugin</span><span>right: model, what it may touch</span>%s</div><div class="agents">' % MARK_LEGEND)
    for a in sorted(agents, key=lambda a: (PLUGIN_ORDER.index(a["plugin"]) if a["plugin"] in PLUGIN_ORDER else 9, a["name"])):
        color = "var(--c-%s)" % a["plugin"] if a["plugin"] in by_plugin else "var(--muted)"
        o.append(agent_card(a, color))
    o.append("</div>")
    o.append(MARK_GROUP)
    o.append("</section>")
    # install
    o.append('<section id="install"><h2><i>06</i>Install</h2><div class="install">')
    o.append('<div><b>Claude</b><pre>claude plugin marketplace add FilipposKaragiannis/brain\nclaude plugin install &lt;plugin&gt;@brain-plugins --scope project\n/standards:init  /flow:init</pre></div>')
    o.append('<div><b>Codex</b><pre>codex plugin marketplace add FilipposKaragiannis/brain\ncodex plugin add &lt;plugin&gt;@brain-plugins\n[plugins."&lt;plugin&gt;@brain-plugins"] enabled = true in .codex/config.toml\n/hooks once to trust the plugin hooks  $init</pre></div>')
    o.append("</div></section>")
    o.append("</main>")
    o.append("<script>%s</script>" % JS)
    page = "\n".join(o) + "\n"
    return inject(page, load_roster(project_roster)) if project_roster else page


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description="Render the map to stdout, optionally with a project's roster beside the plugin agents.")
    ap.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--roster", help="a project's roster JSON (project.roster in .standards/config.json)")
    args = ap.parse_args()
    sys.stdout.write(render_map(args.root, args.roster))

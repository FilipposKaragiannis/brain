#!/bin/sh
# help.sh [<skill> | lines | gates]: the flow's manual, read from the installed plugin.
#   (none)    every skill: what it does, how to call it, whether it runs by itself
#   <skill>   one skill in detail: description, then its steps
#   lines     the steps each kind and size of item runs, and where it stops
#   gates     what each gate is and what the owner answers
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -I - "$here" "${1:-}" <<'PY'
import glob, json, os, re, sys
root, arg = sys.argv[1], sys.argv[2]
def fm(path):
    t = open(path, encoding="utf-8").read().split("---", 2)
    d = {}
    for line in t[1].splitlines():
        m = re.match(r"^([A-Za-z-]+):\s*(.*)$", line)
        if m: d[m.group(1)] = m.group(2).strip()
    return d, t[2]
def yaml_val(path, key):
    try:
        for line in open(path, encoding="utf-8"):
            m = re.match(r'\s*%s:\s*"?(.*?)"?\s*$' % key, line)
            if m: return m.group(1)
    except OSError: pass
    return ""
skills = []
for p in sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))):
    d, body = fm(p)
    name = d.get("name", os.path.basename(os.path.dirname(p)))
    y = os.path.join(os.path.dirname(p), "agents", "openai.yaml")
    skills.append({"name": name, "desc": d.get("description", ""), "auto": d.get("disable-model-invocation") != "true",
                   "short": yaml_val(y, "short_description"), "example": yaml_val(y, "default_prompt"), "body": body})
profiles = json.load(open(os.path.join(root, "profiles.json")))
def lines():
    print("# The lines\n\nKind and size pick a line. A run follows it and stops at every `gate:`.\n")
    label = {"bugfix": "bug", "task-S": "task S", "task-M": "task M", "task-L": "task L or XL", "epic": "epic"}
    for k, steps in profiles["profiles"].items():
        print("- **%s**: %s" % (label.get(k, k), " > ".join(("[%s]" % s[5:]) if s.startswith("gate:") else s for s in steps)))
    print("\n[brackets] = a gate: the run stops and asks you. `help gates` explains each.")
def gates():
    print("# The gates\n")
    ask = {"interview": "confirm the recap of the spec", "decomposition": "check the task list, sizes and blockers",
           "plan-approval": "read plan.md; approve or send it back", "feel-test": "launch it and say how it feels",
           "merge": "merge the PR on the host; the next job clears it", "escalation": "a step failed three times; say what to do",
           "ambiguity": "an agent needs a decision; give it"}
    for g, v in profiles["gates"].items():
        print("- **%s** (raised by %s): %s. Answer: `flow:gate <item> \"<answer>\"`." % (g, v["raised_by"], ask.get(g, v["says"])))
    print("\nSend the work back instead: `gate.sh clear <item> --back \"<what to change>\"` runs the gate's step again with your note (interview, decomposition, plan-approval, feel-test).")
    print("\nConfig can clear `plan-approval` itself by item size (`auto_gates` in `.flow/config.yaml`). Nothing else is auto.")
def one(name):
    s = next((x for x in skills if x["name"] == name), None)
    if not s:
        print("No skill named %s. `help` lists them." % name); sys.exit(1)
    print("# %s\n" % name)
    print("Claude: `/flow:%s <args>`   Codex: `$%s <args>`   %s\n" % (name, name, "runs by itself when the ask fits, or call it" if s["auto"] else "runs only when you call it (or through `do`)"))
    print(s["desc"] + "\n")
    print("\n".join(s["body"].strip().splitlines()[:45]))
def allskills():
    print("# flow\n\nSay it in plain words with `do`, or call a skill by name. `help <skill>` shows one in detail.\n")
    print("| Skill | Does | Claude | Codex | Runs |\n|---|---|---|---|---|")
    for s in skills:
        print("| %s | %s | `/flow:%s` | `$%s` | %s |" % (s["name"], s["short"] or s["desc"].split(".")[0], s["name"], s["name"], "by itself or called" if s["auto"] else "when called"))
    print("\nOthers: `help lines` (the steps per kind and size), `help gates` (what each stop asks of you).")
if arg == "lines": lines()
elif arg == "gates": gates()
elif arg: one(arg)
else: allskills()
PY

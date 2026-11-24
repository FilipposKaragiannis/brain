#!/bin/sh
# Tests for the meta plugin: the skill scaffolder. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; P="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
# No test reaches the network, the desktop or a real agent: these tools are stubs that log to
# $work/offline.log. A test that needs one of them puts its own fake earlier in PATH.
mkdir -p "$work/offline"
for tool in curl wget gh osascript notify-send claude codex; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
echo "scaffold"
mkdir -p "$work/plug"
printf '{"name":"plug","version":"0.1.0","description":"x","skills":[]}\n' > "$work/plug/plugin.source.json"
"$P/skills/write-a-skill/scripts/scaffold.sh" "$work/plug" tidy-up --short "Tidy a module" >/dev/null; code=$?
check "scaffold exits 0" [ "$code" -eq 0 ]
check "SKILL.md with name and description" sh -c "grep -q '^name: tidy-up$' '$work/plug/skills/tidy-up/SKILL.md' && grep -q '^description: Tidy a module' '$work/plug/skills/tidy-up/SKILL.md'"
check "model-invoked: no disable flag" sh -c "! grep -q disable-model-invocation '$work/plug/skills/tidy-up/SKILL.md'"
check "eval case written" [ -f "$work/plug/evals/tidy-up-works/case.yaml" ] && [ -f "$work/plug/evals/tidy-up-works/prompt.md" ] && [ -x "$work/plug/evals/tidy-up-works/scaffold.sh" ]
# The eval CLI reads max_turns, timeout_seconds and allowed_tools only under execution: in
# case.yaml; at the top level they are dropped without a warning.
check "eval settings under execution" sh -c "grep -q '^execution:$' '$work/plug/evals/tidy-up-works/case.yaml' && grep -q '^  max_turns: ' '$work/plug/evals/tidy-up-works/case.yaml' && ! grep -q '^max_turns:' '$work/plug/evals/tidy-up-works/case.yaml'"
check "registered in plugin.source.json" sh -c "python3 -c \"import json; d=json.load(open('$work/plug/plugin.source.json')); s=d['skills'][0]; assert s['name']=='tidy-up' and s['invocation']=='model'\""
"$P/skills/write-a-skill/scripts/scaffold.sh" "$work/plug" ship-it --user --short "Ship it" >/dev/null
check "user-invoked: flag and command prompt" sh -c "grep -q 'disable-model-invocation: true' '$work/plug/skills/ship-it/SKILL.md' && grep -q '^/plug:ship-it' '$work/plug/evals/ship-it-works/prompt.md'"
"$P/skills/write-a-skill/scripts/scaffold.sh" "$work/plug" ship-it >/dev/null 2>&1; code=$?
check "refuses an existing skill" [ "$code" -eq 1 ]
"$P/skills/write-a-skill/scripts/scaffold.sh" "$work/plug" "Bad Name" >/dev/null 2>&1; code=$?
check "refuses a bad name" [ "$code" -eq 2 ]
echo "map"
root="$(cd "$P/../.." && pwd)"
map="$(python3 "$root/tools/lib/map.py" --root "$root")"
check "map renders every skill" sh -c "for s in \$(ls -d '$root'/plugins/*/skills/*/ | xargs -n1 basename | sort -u); do printf '%s' \"\$0\" | grep -q \"<code>\$s</code>\" || exit 1; done" "$map"
check "map renders every agent" sh -c "for a in \$(python3 -c \"import json; print(' '.join(json.load(open('$root/roster/agents.json'))['agents']))\"); do printf '%s' \"\$0\" | grep -q \"<code>\$a</code>\" || exit 1; done" "$map"
check "map draws the profiles and the hooks" sh -c "printf '%s' \"\$0\" | grep -q 'task-L' && printf '%s' \"\$0\" | grep -q 'delivery gate'" "$map"
check "the flows guide names only real skills, agents and scripts" python3 -I -c "
import sys; sys.path.insert(0, '$root/tools/lib')
import map as m, flow_guide as guide
plugins, agents, _ = m.load('$root')
skills = {plugin['name'] + ':' + skill['name'] for plugin in plugins for skill in plugin['skills']}
names = {agent['name'] for agent in agents}
steps = guide.DRIVE + guide.EXTRAS + [step for run in guide.RUNS for step in run['steps']]
bad = [step['command'][0] for step in steps if step.get('command') and step['command'][0] not in skills]
bad += [agent for step in steps for agent in step.get('agents', []) if agent not in names]
import os
flow = '$root/plugins/flow'
for step in steps:
    if step.get('shell'):
        script = step['shell'].split()[0].split('.flow/')[-1]
        if not (os.path.exists(os.path.join(flow, script)) or os.path.exists(os.path.join(flow, 'templates', os.path.basename(script)))):
            bad.append(step['shell'])
sys.exit(1 if bad else 0)"
flows_section="$(printf '%s' "$map" | python3 -I -c "import re, sys; found = re.search(r'<section id=\"flows\".*?</section>', sys.stdin.read(), re.S); print(found.group(0) if found else '')")"
check "MapPage_HasAFlowsSection: the page keeps one section for the flows, because a new reader finds them there" [ -n "$flows_section" ]
check "MapPage_HasNoPlaybooksSection: no element carries a playbooks id, because each flow is said once, in Flows" sh -c "! printf '%s' \"\$0\" | grep -qi 'id=\"[^\"]*playbook'" "$map"
check "MapPage_EveryInPageLinkResolves: each #anchor link has its target, because no link may point at the removed section" python3 -I -c "
import re, sys
page = sys.argv[1]
targets = set(re.findall(r'href=\"#([^\"]+)\"', page))
ids = set(re.findall(r'id=\"([^\"]+)\"', page))
sys.exit(1 if targets - ids else 0)" "$map"
check "Repository_NoFileLinksToPlaybooks: no doc or plugin file links a playbooks anchor, because that section is gone" sh -c "! grep -rIil --exclude-dir=node_modules --exclude-dir=tests --exclude-dir=changelog.d --exclude=CHANGELOG.md '#playbook' '$root/docs' '$root/plugins' '$root/README.md'"
check "FlowsSection_NamesEveryGate: each gate the flow profiles define is named in Flows, because the diamonds the playbooks explained now live there" python3 -I -c "
import json, sys
gates = json.load(open('$root/plugins/flow/profiles.json'))['gates']
sys.exit(1 if [gate for gate in gates if gate not in sys.argv[1]] else 0)" "$flows_section"
check "FlowsSection_SaysWhatEachGateAsks: each gate's ask from the flow profiles shows in Flows, because the reader learns there how to answer a diamond" python3 -I -c "
import html, json, sys
gates = json.load(open('$root/plugins/flow/profiles.json'))['gates']
section = html.unescape(sys.argv[1])
sys.exit(1 if [name for name, gate in gates.items() if gate['asks'] not in section] else 0)" "$flows_section"
check "FlowsSection_ShowsTheGateCommand: Flows shows the flow:gate command, because it is how the reader answers a diamond" sh -c "printf '%s' \"\$0\" | grep -q '/flow:gate'" "$flows_section"
check "CommittedPage_HasNoDrift: tools/generate.sh --check finds every generated file fresh, because the committed map must match what the sources render" "$root/tools/generate.sh" --check
printf '{"agents":{"physics-reviewer":{"tier":"read-only","model":"opus","effort":"high","description":"Reviews physics. Use when src/Physics changes."}}}\n' > "$work/project-roster.json"
check "map with a project roster lists it beside the plugin agents" sh -c "python3 '$root/tools/lib/map.py' --root '$root' --roster '$work/project-roster.json' | grep -q 'This project (1)' && ! printf '%s' \"\$0\" | grep -q 'This project'" "$map"
check "the plugin ships the page, same as docs/map.html" cmp -s "$root/plugins/meta/skills/map/assets/map.html" "$root/docs/map.html"
mkdir -p "$work/elsewhere"
check "the plugin's script fills the roster from outside the marketplace" sh -c "cd '$work/elsewhere' && python3 -I '$root/plugins/meta/skills/map/scripts/project_map.py' --roster '$work/project-roster.json' --out page.html >/dev/null && grep -q 'This project (1)' page.html && grep -q '<code>physics-reviewer</code>' page.html && grep -q 'agents (+1 yours)' page.html && grep -q 'dashed: this project' page.html"
check "the script and the marketplace render the same page" sh -c "python3 '$root/tools/lib/map.py' --root '$root' --roster '$work/project-roster.json' | cmp -s - '$work/elsewhere/page.html'"
"$root/tools/map.sh" --roster "$work/project-roster.json" --out "$work/roster-map.html" >/dev/null 2>&1; code=$?
check "MapScript_WithRosterExitsZero: tools/map.sh --roster succeeds, because a reader renders a project's map with it" [ "$code" -eq 0 ]
check "MapScript_WithRosterListsTheProjectAgents: the written page lists the project roster, because --roster shows a project's agents beside the plugin ones" grep -q '<code>physics-reviewer</code>' "$work/roster-map.html"
[ "$fails" -eq 0 ] && { echo "meta: ok"; exit 0; }
echo "meta: $fails failed"; exit 1

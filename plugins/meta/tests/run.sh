#!/bin/sh
# Tests for the meta plugin: the skill scaffolder. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; P="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# No test reaches the network, the desktop or a real agent. The owner's shell may export
# FLOW_SLACK_WEBHOOK, so it is cleared, and these tools are stubs that log to $work/offline.log.
# A test that needs one of them puts its own fake earlier in PATH.
unset FLOW_SLACK_WEBHOOK
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
check "playbooks name only real skills and agents" python3 -I -c "
import sys; sys.path.insert(0, '$root/tools/lib')
import map as m, playbooks as pb
plugins, agents, _ = m.load('$root')
skills = {p['name'] + ':' + s['name'] for p in plugins for s in p['skills']}
names = {a['name'] for a in agents}
bad = [st['cmd'][0] for b in pb.PLAYBOOKS + [{'steps': pb.EXTRAS}] for st in b['steps'] if st.get('cmd') and st['cmd'][0] not in skills]
bad += [a for b in pb.PLAYBOOKS for st in b['steps'] for a in st.get('who', []) if a not in names]
import os
flow = '$root/plugins/flow'
for b in pb.PLAYBOOKS:
    for st in b['steps']:
        if st.get('sh'):
            script = st['sh'].split()[0].split('.flow/')[-1]
            if not (os.path.exists(os.path.join(flow, script)) or os.path.exists(os.path.join(flow, 'templates', os.path.basename(script)))):
                bad.append(st['sh'])
sys.exit(1 if bad else 0)"
printf '{"agents":{"physics-reviewer":{"tier":"read-only","model":"opus","effort":"high","description":"Reviews physics. Use when src/Physics changes."}}}\n' > "$work/project-roster.json"
check "map with a project roster lists it beside the plugin agents" sh -c "python3 '$root/tools/lib/map.py' --root '$root' --roster '$work/project-roster.json' | grep -q 'This project (1)' && ! printf '%s' \"\$0\" | grep -q 'This project'" "$map"
check "the plugin ships the page, same as docs/map.html" cmp -s "$root/plugins/meta/skills/map/assets/map.html" "$root/docs/map.html"
mkdir -p "$work/elsewhere"
check "the plugin's script fills the roster from outside the marketplace" sh -c "cd '$work/elsewhere' && python3 -I '$root/plugins/meta/skills/map/scripts/project_map.py' --roster '$work/project-roster.json' --out page.html >/dev/null && grep -q 'This project (1)' page.html && grep -q '<code>physics-reviewer</code>' page.html && grep -q 'agents (+1 yours)' page.html && grep -q 'dashed: this project' page.html"
check "the script and the marketplace render the same page" sh -c "python3 '$root/tools/lib/map.py' --root '$root' --roster '$work/project-roster.json' | cmp -s - '$work/elsewhere/page.html'"
check "map shows the five playbooks" sh -c "printf '%s' \"\$0\" | grep -c 'class=\"pb\"' | grep -qx 5" "$map"
[ "$fails" -eq 0 ] && { echo "meta: ok"; exit 0; }
echo "meta: $fails failed"; exit 1

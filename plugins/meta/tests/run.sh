#!/bin/sh
# Tests for the meta plugin: the skill scaffolder. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; P="$(cd "$here/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
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
map="$(python3 "$root/tools/lib/map.py" "$root")"
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
sys.exit(1 if bad else 0)"
check "map shows the four playbooks" sh -c "printf '%s' \"\$0\" | grep -c 'class=\"pb\"' | grep -qx 4" "$map"
[ "$fails" -eq 0 ] && { echo "meta: ok"; exit 0; }
echo "meta: $fails failed"; exit 1

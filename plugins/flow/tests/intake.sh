#!/bin/sh
# intake.sh: intake on fake hosts.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_github_fixture.sh"
. "$here/_jobs_fixture.sh"
echo "intake (fake hosts)"
cat > "$work/notes.md" <<'MD'
# Notes:

- First note, with a detail
	- sub line under it

## Bugs:

- Second note
- [x] already done
- filed long ago #promoted -> #3

### Code
- Third note
	```c#
	var x = 1;
	```
MD
python3 -I "$P/scripts/_intake.py" parse "$work/notes.md" "$work/none.jsonl" 10 > "$work/parsed.json"
check "intake parse: bullets with their sub-lines, checked and promoted ones skipped" sh -c "python3 -c 'import json; d=json.load(open(\"$work/parsed.json\")); n=d[\"notes\"]; assert [x[\"id\"] for x in n]==[\"n1\",\"n2\",\"n3\"] and \"sub line\" in n[0][\"text\"] and \"var x\" in n[2][\"text\"] and d[\"left\"]==0'"
check "intake parse: the section is the heading chain" sh -c "python3 -c 'import json; n=json.load(open(\"$work/parsed.json\"))[\"notes\"]; assert (n[0][\"section\"],n[2][\"section\"])==(\"Notes\",\"Notes > Bugs > Code\")'"
check "intake parse: the batch caps it and counts the rest" sh -c "python3 -I '$P/scripts/_intake.py' parse '$work/notes.md' '$work/none.jsonl' 1 | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d[\"notes\"])==1 and d[\"left\"]==2'"
cat > "$work/bin/claude" <<'SH'
#!/bin/sh
printf '%s\t%s\t%s\n' "$0" "$PWD" "$*" >> "$HOST_LOG"
out="$(printf '%s' "$*" | sed -n 's/.* and write \([^ ]*results.json\).*/\1/p')"
[ -n "$out" ] && [ -z "${FAKE_NO_RESULTS:-}" ] && python3 -c "
import json, os, sys
n = json.load(open(os.path.join(os.path.dirname(sys.argv[1]), 'notes.json')))['notes'][0]
o = 'filed' if 'First' in n['text'] else 'duplicate' if 'Second' in n['text'] else 'kept'
json.dump([{'note': n['id'], 'outcome': o, 'issues': []}], open(sys.argv[1], 'w'))" "$out"
exit 0
SH
chmod +x "$work/bin/claude"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\njobs:\n  permission_mode: auto\nintake:\n  notes: %s\n' "$work/notes.md" > "$home2/config.yaml"
cp "$work/notes.md" "$work/notes.orig"
check "intake job: no notes file is quiet" sh -c "FLOW_HOME='$home2' '$P/jobs/intake.sh' claude --notes '$work/missing.md' | grep -q 'quiet: no notes file'"
FAKE_NO_RESULTS=1 FLOW_HOME="$home2" "$P/jobs/intake.sh" claude >/dev/null 2>&1; code=$?
check "intake job: no results file fails and leaves the notes" sh -c "[ $code -eq 1 ] && cmp -s '$work/notes.md' '$work/notes.orig'"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude > "$work/intake.out"
check "intake job: one session per note, with jobs.permission_mode" sh -c "[ \$(grep -c -- '-p /flow:intake on' '$HOST_LOG') = 3 ] && grep -q -- '--permission-mode auto' '$HOST_LOG'"
check "intake job: filed and duplicate notes leave the file, kept ones and headings stay" sh -c "! grep -q 'First note' '$work/notes.md' && ! grep -q 'sub line' '$work/notes.md' && ! grep -q 'Second note' '$work/notes.md' && grep -q 'Third note' '$work/notes.md' && grep -q '^## Bugs' '$work/notes.md' && grep -q 'already done' '$work/notes.md'"
check "intake job: removing a note leaves the blank lines elsewhere as they were" sh -c "python3 -c 'import sys; s=open(sys.argv[1]).read(); assert \"\\n\\n\\n\" not in s and s.startswith(\"# Notes:\\n\\n## Bugs:\\n\\n- [x]\")' '$work/notes.md'"
check "intake job: the ledger records the handled notes" [ "$(wc -l < "$home2/log/intake-ledger.jsonl" | tr -d ' ')" = 2 ]
check "intake job: says what it did" grep -q 'done: duplicate 1 filed 1 kept 1' "$work/intake.out"
cp "$work/notes.orig" "$work/kept.md"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude --notes "$work/kept.md" --keep-notes >/dev/null
check "intake job: --keep-notes leaves the file and the ledger skips what it filed" sh -c "cmp -s '$work/kept.md' '$work/notes.orig' && [ \$(grep -c -- '-p /flow:intake on' '$HOST_LOG') = 1 ] && grep -q 'Third note' \$(grep -l Third '$home2'/tmp/intake-*/n1/notes.json | tail -1)"
cat > "$work/old.md" <<'MD'
## Bots

- [ ] Ball spins forever  #bug  ^spin
    - desc: after a goalpost edge
    - rel: ^refl
- [ ] Why does a free rod swing?  ^why
- [ ] Old net settings  #parked  ^net
- [ ] Vague thing  ^vague
- [ ] Spins again #dup (see ^spin) ^spin2
MD
printf '{"hash":"x","outcome":"filed","issues":["gh#5"],"ref":"refl","rel":[]}\n' > "$work/old-ledger.jsonl"
python3 -I "$P/scripts/_intake.py" parse "$work/old.md" "$work/old-ledger.jsonl" 10 > "$work/old.json"
check "intake parse: title, tags, handle and rel from the note" sh -c "python3 -c 'import json; n=json.load(open(\"$work/old.json\"))[\"notes\"][0]; assert (n[\"title\"],n[\"tags\"],n[\"ref\"],n[\"rel\"])==(\"Ball spins forever\",[\"bug\"],\"spin\",[\"refl\"]), n'"
check "intake parse: related notes carry the items already filed for them" sh -c "python3 -c 'import json; n=json.load(open(\"$work/old.json\"))[\"notes\"][0]; assert n[\"related\"]==[{\"ref\":\"refl\",\"issues\":[\"gh#5\"],\"outcome\":\"filed\"}], n'"
check "intake parse: a title ending in ? is a question, #dup names its handle, #parked is a plain tag" sh -c "python3 -c 'import json; n=json.load(open(\"$work/old.json\"))[\"notes\"]; assert n[1][\"question\"] and not n[0][\"question\"] and n[4][\"dup\"]==\"spin\" and n[4][\"ref\"]==\"spin2\" and n[2][\"tags\"]==[\"parked\"]'"
cat > "$work/bin/claude" <<'SH'
#!/bin/sh
printf '%s\t%s\t%s\n' "$0" "$PWD" "$*" >> "$HOST_LOG"
out="$(printf '%s' "$*" | sed -n 's/.* and write \(.*results\.json\)\. Unattended.*/\1/p')"
python3 -c "
import json, os, sys
d = json.load(open(os.path.join(os.path.dirname(sys.argv[1]), 'notes.json'))); n = d['notes'][0]
open(os.environ['HOST_LOG'], 'a').write('vocabulary %s %s\n' % (d['types'], d['areas']))
open(os.environ['HOST_LOG'], 'a').write('rules %s\n' % d['rules'])
row = {'note': n['id'], 'outcome': 'filed', 'issues': ['gh#9']}
if n['question']: row = {'note': n['id'], 'outcome': 'answered', 'issues': [], 'title': n['title'], 'answer': 'The ball gives it momentum.\n\nSee \`Rod.cs:12\`.'}
if 'Old' in n['title']: row = {'note': n['id'], 'outcome': 'dropped', 'issues': [], 'reason': 'The net settings were removed in gh#120.'}
if 'Vague' in n['title']: row = {'note': n['id'], 'outcome': 'dropped', 'issues': []}
json.dump([row], open(sys.argv[1], 'w'))" "$out"
SH
chmod +x "$work/bin/claude"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude --notes "$work/old.md" > "$work/old.out" 2>&1
check "intake job: an answered question goes to the answers page, not the tracker" sh -c "grep -q '^# Answers' '$work/answers.md' && grep -q '^## Why does a free rod swing?' '$work/answers.md' && grep -q 'Rod.cs:12' '$work/answers.md' && grep -q 'From the notes (Bots), answered' '$work/answers.md' && ! grep -q 'free rod' '$work/old.md'"
check "intake job: a dropped note goes to the dropped page with its reason" sh -c "grep -q '^- \*\*Old net settings\*\* (Bots), .*: The net settings were removed in gh#120.' '$work/dropped.md' && ! grep -q 'Old net' '$work/old.md'"
check "intake job: a drop without a reason is kept" sh -c "grep -q 'Vague thing' '$work/old.md' && ! grep -q Vague '$work/dropped.md' && grep -q 'dropped without a reason, kept' '$home2/log/intake.log'"
check "intake job: the ledger keeps each note's handle and links for the notes after it" sh -c "grep '\"ref\": \"spin2\"' '$home2/log/intake-ledger.jsonl' | grep -q '\"rel\": \[\"spin\"\]'"
check "intake job: the summary counts answered and dropped" grep -q 'done: answered 1 dropped 1 filed 2 kept 1' "$work/old.out"
check "intake job: a tracker without types or areas sends empty lists" grep -q 'vocabulary \[\] \[\]' "$HOST_LOG"
check "intake job: without project rules each session gets flow's default rules" sh -c "grep -qx 'rules $P/skills/intake/rules.md' '$HOST_LOG' && [ -s '$P/skills/intake/rules.md' ]"
here="$(pwd)"; mkdir -p "$work/notesrepo" && cd "$work/notesrepo" && git init -q --bare origin.git && git clone -q origin.git app 2>/dev/null && cd app && git config user.email t@t && git config user.name t
mkdir -p docs .flow && cp "$work/notes.orig" docs/notes.md && printf -- '- How does a pin hold?\n' >> docs/notes.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init && git push -q origin HEAD:main 2>/dev/null && git branch -q -M main && git branch -q -u origin/main
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\nintake:\n  notes: docs/notes.md\n' > .flow/config.yaml
"$P/jobs/intake.sh" claude > "$work/notesrepo.out" 2>&1
check "intake job: a tracked notes file is committed with its answers page, alone, and pushed" sh -c "git -C '$work/notesrepo/origin.git' log -1 --format=%s main | grep -q '^chore(notes)' && ! git -C '$work/notesrepo/origin.git' show main:docs/notes.md | grep -q 'First note' && git -C '$work/notesrepo/origin.git' show main:docs/answers.md | grep -q '^## How does a pin hold?' && [ \"\$(git -C '$work/notesrepo/origin.git' show --name-only --format= main | tr '\n' ' ')\" = 'docs/answers.md docs/notes.md ' ]"
printf 'x\n' > other.txt && git add other.txt && git commit -qm other && printf -- '- Fourth note\n' >> docs/notes.md
"$P/jobs/intake.sh" claude >> "$work/notesrepo.out" 2>&1
check "intake job: other unpushed commits hold the push back" sh -c "grep -q 'other unpushed changes' .flow/log/intake.log && ! git -C '$work/notesrepo/origin.git' log --format=%s main | grep -q '^other'"
cd "$here"
notes_clone() { # notes_clone <dir> <more intake config>: <dir>/origin.git and its clone <dir>/app, notes with a question
  mkdir -p "$1" && git init -q --bare "$1/origin.git" && git clone -q "$1/origin.git" "$1/app" 2>/dev/null && (cd "$1/app" &&
    git config user.email t@t && git config user.name t && mkdir -p docs .flow && cp "$work/notes.orig" docs/notes.md &&
    printf -- '- How does a pin hold?\n' >> docs/notes.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init &&
    git push -q origin HEAD:main 2>/dev/null && git branch -q -M main && git branch -q -u origin/main &&
    printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\nintake:\n  notes: docs/notes.md\n%b' "$2" > .flow/config.yaml)
}
notes_clone "$work/notes repo" ""
(cd "$work/notes repo/app" && "$P/jobs/intake.sh" claude) > "$work/space.out" 2>&1
check "intake job: a repo path with a space still commits the notes and the page" sh -c "[ \"\$(git -C '$work/notes repo/origin.git' show --name-only --format= main | tr '\n' ' ')\" = 'docs/answers.md docs/notes.md ' ] && ! git -C '$work/notes repo/origin.git' show main:docs/notes.md | grep -q 'First note'"
notes_clone "$work/ignored" "  answers: .flow/answers.md\n"
(cd "$work/ignored/app" && "$P/jobs/intake.sh" claude) > "$work/ignored.out" 2>&1
check "intake job: an ignored answers page is left out and the notes are still committed" sh -c "[ \"\$(git -C '$work/ignored/origin.git' show --name-only --format= main)\" = docs/notes.md ] && grep -q 'pin hold' '$work/ignored/app/.flow/answers.md' && grep -q 'git ignores .flow/answers.md' '$work/ignored.out'"
notes_clone "$work/ownrules" ""
printf '# Our rules\n' > "$work/ownrules/app/.flow/intake.md"; : > "$HOST_LOG"
(cd "$work/ownrules/app" && "$P/jobs/intake.sh" claude) > /dev/null 2>&1
check "intake job: a project's .flow/intake.md is the rules each session gets" sh -c "grep -q '^rules .*/ownrules/app/.flow/intake.md\$' '$HOST_LOG' && ! grep -q 'skills/intake/rules.md' '$HOST_LOG'"
notes_clone "$work/badrules" "  rules: docs/missing-rules.md\n"; : > "$HOST_LOG"
(cd "$work/badrules/app" && "$P/jobs/intake.sh" claude) > "$work/badrules.out" 2>&1; code=$?
check "intake job: intake.rules naming a missing file fails before any session" sh -c "[ $code -ne 0 ] && grep -q 'intake.rules names .*missing-rules.md, which does not exist' '$work/badrules.out' && [ ! -s '$HOST_LOG' ]"
cat > "$work/batch.md" <<'MD'
## Batch

- Ball rolls off the rail ^bat1
- Rolls off again #dup (see ^bat1) ^bat2
- Gone rail guard ^bat3
- Guard again #dup (see ^bat3) ^bat4
- Speed grows as x^2 [^1] ^bat5
- Why does it bend?
MD
python3 -I "$P/scripts/_intake.py" parse "$work/batch.md" "$work/none.jsonl" 10 > "$work/batch.json"
check "intake parse: a caret inside a word or a footnote is not a handle" sh -c "python3 -c 'import json; n=json.load(open(\"$work/batch.json\"))[\"notes\"][4]; assert (n[\"title\"],n[\"ref\"])==(\"Speed grows as x^2 [^1]\",\"bat5\"), n'"
cat > "$work/bin/claude" <<'SH'
#!/bin/sh
out="$(printf '%s' "$*" | sed -n 's/.* and write \(.*results\.json\)\. Unattended.*/\1/p')"
python3 -c "
import json, os, sys
n = json.load(open(os.path.join(os.path.dirname(sys.argv[1]), 'notes.json')))['notes'][0]
open(os.environ['HOST_LOG'], 'a').write('related %s %s\n' % (n['ref'], json.dumps(n['related'], sort_keys=True)))
row = {'note': n['id'], 'outcome': 'filed', 'issues': ['gh#7' + n['id'][1:]]}
if 'Gone' in n['title']: row = {'note': n['id'], 'outcome': 'dropped', 'issues': [], 'reason': 'The rail\nwas removed.'}
if n['question']: row = {'note': n['id'], 'outcome': 'answered', 'issues': [], 'title': 'Why does it\n  bend?', 'answer': 'It bends.'}
json.dump([row], open(sys.argv[1], 'w'))" "$out"
SH
chmod +x "$work/bin/claude"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude --notes "$work/batch.md" > "$work/batch.out" 2>&1
seen() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    if l.startswith("related %s " % sys.argv[2]): print(l.split(" ", 2)[2].strip())' "$HOST_LOG" "$1"; }
check "intake job: a #dup sees the item its target filed earlier in the same run" [ "$(seen bat2)" = '[{"issues": ["gh#71"], "outcome": "filed", "ref": "bat1"}]' ]
check "intake job: a #dup of a dropped note sees it dropped, with its reason" [ "$(seen bat4)" = '[{"issues": [], "outcome": "dropped", "reason": "The rail was removed.", "ref": "bat3"}]' ]
check "intake job: a model title with a newline gives a one-line heading" sh -c "grep -qx '## Why does it bend?' '$work/answers.md'"
check "jobs.permission_mode refuses anything but dontAsk or auto" sh -c "FLOW_PERMISSION_MODE=bypassPermissions FLOW_PLUGIN='$P' sh -c '. \"$P/lib/host.sh\"; host_permission_mode' 2>&1 | grep -q 'dontAsk or auto'"
printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' > "$work/bin/claude"; chmod +x "$work/bin/claude"

[ "$fails" -eq 0 ] && { echo "intake: ok"; exit 0; }
echo "intake: $fails failed"; exit 1

#!/bin/sh
# health.sh: the health job, its planned holds, and init's stamp, guard and session-start nudge.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_github_fixture.sh"
echo "health"
hroot="$work/health"; mkdir -p "$hroot"
git init -q --bare "$hroot/origin.git"
git clone -q "$hroot/origin.git" "$hroot/app" 2>/dev/null
cd "$hroot/app" || exit 1
git config user.email t@t && git config user.name t
git symbolic-ref HEAD refs/heads/main
printf 'hi\n' > README.md && git add -A && git commit -qm init && git push -q -u origin main
for n in 1 2 3; do git worktree add -q -b "main-wt-$n" "../wt-$n"; done
mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\n  - ../wt-3\npool_max: 3\nnotify:\n  desktop: true\njobs:\n  schedule:\n    health: every 15m\n  health:\n    behind_base: 2\n' > .flow/config.yaml
git clone -q "$hroot/origin.git" "$hroot/other" 2>/dev/null
git -C "$hroot/other" config user.email t@t && git -C "$hroot/other" config user.name t
hs() { "$P/scripts/steward.sh" health "$@"; }
hitem() { "$P/adapters/local/create.sh" task "$1" --size S --body "x"; }
. "$here/_claimed_worktree_fixture.sh"
rec() { printf '%s/.flow/runs/%s.json' "$hroot/app" "$(item_slug "$1")"; }
age_run() { python3 -c '
import json, sys, time
p, pid = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["started"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 172800))
d.pop("pid", None)
if pid != "-": d["pid"] = int(pid)
json.dump(d, open(p, "w"))' "$(rec "$1")" "${2:-999999}"; }
stale_claim() { python3 -c '
import json, sys, time
p = sys.argv[1] + "/.flow/claim.json"
d = json.load(open(p)); d["claimed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 172800)); json.dump(d, open(p, "w"))' "$1"
  find "$1/.flow/reports" -exec touch -t 202401010000 {} + 2>/dev/null; }
remote_commit() { git -C "$hroot/other" fetch -q origin && git -C "$hroot/other" checkout -q -B "$1" "origin/$1" && printf '%s\n' "$2" > "$hroot/other/$2.txt" && git -C "$hroot/other" add -- "$2.txt" && git -C "$hroot/other" commit -qm "$2" && git -C "$hroot/other" push -q origin "$1"; }
facts() { n="$(grep -c "$1" .flow/events.log 2>/dev/null)"; echo "${n:-0}"; }
pings() { n="$(grep -c 'flow: health' "$work/offline.log" 2>/dev/null)"; echo "${n:-0}"; }
# The resumed session dies with its run: it kills the run-unattended loop above it and the loop's
# subshells (they share its command line), as a crash would, so the run record stays and no
# result is read. A session that exits with no result is a failed attempt since gh#169, not a
# dead run, so it cannot stand in for one. The walk up stops at this suite ($$ here): health --wait
# runs the loop in the foreground, and above the suite sits the real loop of the step that runs
# these tests, which the walk killed too, so every such step died as often as it ran the suite.
cat > "$work/bin/claude" <<EOF
#!/bin/sh
printf '%s\t%s\n' "\$PWD" "\$*" >> "$hroot/host.log"
doomed="\$(python3 -I -c '
import os, sys
sys.path.insert(0, sys.argv[1])
import _process
ancestor, doomed = _process.parent_of(os.getppid()), []
while ancestor > 1 and ancestor != int(sys.argv[2]):
    if "run-unattended.sh" in _process.command_of(ancestor):
        doomed.append(str(ancestor))
    ancestor = _process.parent_of(ancestor)
print(" ".join(doomed))' "$P/scripts" "$$")"
[ -z "\$doomed" ] || kill -9 \$doomed
exit 0
EOF
chmod +x "$work/bin/claude"
export FLOW_HEALTH_PROCS="$hroot/procs"; : > "$FLOW_HEALTH_PROCS"; : > "$work/offline.log"

hs > "$hroot/out" 2>&1
check "health: a healthy pool is one quiet line" sh -c "[ \$(wc -l < '$hroot/out' | tr -d ' ') = 1 ] && grep -q 'health: 0 claimed.*3 free.*nothing to do' '$hroot/out'"
"$P/jobs/health.sh" claude >/dev/null
check "health job: nothing to do is a quiet run with no event and no notification" sh -c "grep -q 'quiet: 0 claimed' .flow/log/health.log && tail -1 .flow/log/runs.jsonl | grep -q '\"result\":\"quiet' && [ ! -s .flow/events.log ] && [ \$(grep -c 'flow: health' '$work/offline.log') = 0 ]"
remote_commit main m1
hs > "$hroot/out" 2>&1
check "health: a free worktree follows the base branch tip" sh -c "[ \"\$(git -C ../wt-1 rev-parse HEAD)\" = \"\$(git rev-parse origin/main)\" ] && [ \"\$(git -C ../wt-3 rev-parse HEAD)\" = \"\$(git rev-parse origin/main)\" ] && grep -q 'fast-forwarded free wt-2' '$hroot/out'"
hs > "$hroot/out" 2>&1
check "health: a worktree already at the tip is not a finding" grep -q 'nothing to do' "$hroot/out"
git -C ../wt-3 switch -q --detach origin/main~1
hs > "$hroot/out" 2>&1
check_all "health: a free worktree left detached moves onto its idle branch at the tip" '[ "$(git -C ../wt-3 symbolic-ref --short HEAD)" = main-wt-3 ] && [ "$(git -C ../wt-3 rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && grep -q "moved free wt-3 onto main-wt-3 at main" "$hroot/out"'
git -C ../wt-3 switch -q -c side origin/main~1
hs > "$hroot/out" 2>&1
check_all "health: a free worktree on another branch is said, not moved" 'grep -q "wt-3 is free but on the branch side, so it is not moved" "$hroot/out" && [ "$(git -C ../wt-3 symbolic-ref --short HEAD)" = side ]'
git -C ../wt-3 switch -q main-wt-3 && git -C ../wt-3 branch -q -D side && rm -f .flow/health/free-wt-3-branch.seen
git worktree remove --force ../wt-3
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check_all "health: a pool path missing on disk is a finding with the recreate hint, said once, and counts as free" 'grep -q "^pool: wt-3 is in the pool but missing on disk; the next claim recreates it on main-wt-3 at main, or recreate it now: steward.sh add $(cd .. && pwd -P)/wt-3$" "$hroot/out" && grep -q "0 claimed.*3 free.*1 finding(s)" "$hroot/out" && ! grep -q "missing on disk" "$hroot/out2" && [ ! -d ../wt-3 ]'
"$P/scripts/steward.sh" add "$(cd .. && pwd -P)/wt-3" >/dev/null 2>&1
hs > "$hroot/out" 2>&1
check_all "health: the hint recreates it on its idle branch at the base tip, and health is quiet again" '[ "$(git -C ../wt-3 symbolic-ref --short HEAD)" = main-wt-3 ] && [ "$(git -C ../wt-3 rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && [ "$(grep -c wt-3 .flow/config.yaml)" = 1 ] && grep -q "nothing to do" "$hroot/out" && [ ! -f .flow/health/missing-wt-3.seen ]'
git -C "$hroot/other" fetch -q origin && git -C "$hroot/other" checkout -q -B main origin/main && printf 'hello\n' > "$hroot/other/README.md" && git -C "$hroot/other" commit -qam readme && git -C "$hroot/other" push -q origin main
hs >/dev/null 2>&1
git -C ../wt-2 read-tree -u --reset origin/main~1
hs > "$hroot/out" 2>&1
check_all "health: changes in a free worktree that the base already held are said once and kept on the first run" 'grep -q "^pool: wt-2 is free but has 1 uncommitted change(s), each already in main.s history; the next health run discards them if they stay unchanged and no session works there$" "$hroot/out" && [ "$(cat ../wt-2/README.md)" = hi ] && grep -q "2 free" "$hroot/out"'
hs --dry-run > "$hroot/out" 2>&1
check_all "health --dry-run: says it would discard unchanged redundant changes and keeps them" 'grep -q "would discard the 1 uncommitted change(s) in free wt-2" "$hroot/out" && [ "$(cat ../wt-2/README.md)" = hi ]'
printf '999999\t%s\tclaude\n' "$(cd ../wt-2 && pwd -P)" > "$FLOW_HEALTH_PROCS"
hs > "$hroot/out" 2>&1
check_all "health: redundant changes stay while a session works in the free worktree" '[ "$(cat ../wt-2/README.md)" = hi ] && ! grep -q "discard" "$hroot/out"'
printf '%s\t%s\tclaude\n' "$$" "$(cd ../wt-2 && pwd -P)" > "$FLOW_HEALTH_PROCS"
hs > "$hroot/out" 2>&1
check_all "health: redundant changes stay while the session that called health works in the free worktree" '[ "$(cat ../wt-2/README.md)" = hi ] && ! grep -q "discard" "$hroot/out"'
: > "$FLOW_HEALTH_PROCS"; pings_before="$(pings)"
hs > "$hroot/out" 2>&1
check_all "health: unchanged redundant changes are discarded on the next run, and the owner is told" 'grep -q "^pool: discarded the 1 uncommitted change(s) in free wt-2, each already in main.s history$" "$hroot/out" && [ -z "$(git -C ../wt-2 status --porcelain)" ] && [ "$(cat ../wt-2/README.md)" = hello ] && [ "$(pings)" -gt "$pings_before" ] && grep -q "3 free" "$hroot/out" && [ ! -f .flow/health/free-wt-2.seen ]'
git -C ../wt-2 read-tree -u --reset origin/main~1
hs >/dev/null 2>&1; git -C ../wt-2 rm -q --cached README.md
hs > "$hroot/out" 2>&1
check_all "health: redundant changes that moved since the last run restart the wait" 'grep -q "wt-2 is free but has 2 uncommitted change(s), each already" "$hroot/out" && ! grep -q discarded "$hroot/out" && [ -n "$(git -C ../wt-2 status --porcelain)" ]'
git -C ../wt-2 reset -q --hard && git -C ../wt-2 clean -fdq && printf 'mine\n' > ../wt-2/README.md && printf 'new\n' > ../wt-2/scratch.txt
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check_all "health: changes holding anything of their own are said once with the path, and never discarded" 'grep -q "^pool: wt-2 is free but has uncommitted changes, so no claim can use it: the disk version of README.md is not in origin/main$" "$hroot/out" && ! grep -q "wt-2" "$hroot/out2" && [ "$(cat ../wt-2/README.md)" = mine ] && [ -f ../wt-2/scratch.txt ]'
git -C ../wt-2 checkout -q -- README.md
hs > "$hroot/out" 2>&1
check_all "health: an untracked file the base never held keeps the changes" 'grep -q "so no claim can use it: untracked file scratch.txt is not in origin/main" "$hroot/out" && [ -f ../wt-2/scratch.txt ]'
rm -f ../wt-2/scratch.txt; hs >/dev/null 2>&1
nl_name="$(printf 'a\nb.txt')"; printf 'unique\n' > "../wt-2/$nl_name"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check_all "health: an untracked file whose name holds a newline is hashed on its own, kept and never discarded" 'grep -qF "so no claim can use it: untracked file a\nb.txt is not in origin/main" "$hroot/out" && ! grep -q discard "$hroot/out2" && [ "$(cat "../wt-2/$nl_name")" = unique ]'
rm -f "../wt-2/$nl_name"; hs >/dev/null 2>&1
git -C "$hroot/other" fetch -q origin && git -C "$hroot/other" checkout -q -B main origin/main && mkdir -p "$hroot/other/.flow" && printf 'base\n' > "$hroot/other/.flow/notes.txt" && git -C "$hroot/other" add .flow/notes.txt && git -C "$hroot/other" commit -qm flow-notes && git -C "$hroot/other" push -q origin main
hs >/dev/null 2>&1
printf 'hi\n' > ../wt-2/README.md && printf 'mine\n' > ../wt-2/.flow/notes.txt
hs >/dev/null 2>&1; hs > "$hroot/out" 2>&1
check_all "health: discarding redundant changes restores only the checked paths and keeps a tracked .flow/ edit" 'grep -q "^pool: discarded the 1 uncommitted change(s) in free wt-2" "$hroot/out" && [ "$(cat ../wt-2/README.md)" = hello ] && [ "$(cat ../wt-2/.flow/notes.txt)" = mine ]'
git -C ../wt-2 checkout -q -- .flow/notes.txt; hs >/dev/null 2>&1
git -C ../wt-2 rm -q --cached README.md
hs >/dev/null 2>&1; hs > "$hroot/out" 2>&1
check_all "health: a staged deletion whose file stays on disk is discarded whole, the file kept and tracked again" 'grep -q "^pool: discarded the 2 uncommitted change(s) in free wt-2" "$hroot/out" && [ -z "$(git -C ../wt-2 status --porcelain)" ] && [ "$(cat ../wt-2/README.md)" = hello ]'
common="$(cd ../wt-2 && cd "$(git rev-parse --git-common-dir)" && pwd)"; mkdir -p "$common/info"
printf 'README.md filter=strip\n' > "$common/info/attributes"; git -C ../wt-2 config filter.strip.clean 'grep -v SECRET'
printf 'hello\nSECRET\n' > ../wt-2/README.md
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check_all "health: bytes a clean filter strips are hashed raw, so the file is kept and never discarded" 'grep -q "so no claim can use it: the disk version of README.md is not in origin/main" "$hroot/out" && ! grep -q discard "$hroot/out2" && grep -q SECRET ../wt-2/README.md'
rm -f "$common/info/attributes"; git -C ../wt-2 config --unset filter.strip.clean; git -C ../wt-2 checkout -q -- README.md; hs >/dev/null 2>&1

ended_agent_worktree="$(printf '{"name":"agent-a2bc735e","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
stale_claim "$ended_agent_worktree"; : > "$FLOW_HEALTH_PROCS"
hs > "$hroot/out" 2>&1
check "health: a sub-agent's ad hoc claim whose session has ended is released with no hand step" [ ! -f "$ended_agent_worktree/.flow/claim.json" ]
"$P/scripts/steward.sh" release "$ended_agent_worktree" --force >/dev/null 2>&1

dirty_agent_worktree="$(printf '{"name":"agent-d1e7c0de","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
printf 'unsaved\n' > "$dirty_agent_worktree/sub-agent-notes.txt"; touch -t 202401010000 "$dirty_agent_worktree/sub-agent-notes.txt"
stale_claim "$dirty_agent_worktree"; : > "$FLOW_HEALTH_PROCS"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: an ended sub-agent's ad hoc claim with uncommitted changes is kept" [ -f "$dirty_agent_worktree/.flow/claim.json" ]
check "health: an ended sub-agent's uncommitted changes are never reset" [ "$(cat "$dirty_agent_worktree/sub-agent-notes.txt")" = unsaved ]
dirty_agent_name="$(basename "$dirty_agent_worktree")"
check_all "health: an ended sub-agent's claim with uncommitted changes is named once" 'grep -qw "$dirty_agent_name" "$hroot/out" && ! grep -qw "$dirty_agent_name" "$hroot/out2"'
rm -f "$dirty_agent_worktree/sub-agent-notes.txt"; "$P/scripts/steward.sh" release "$dirty_agent_worktree" --force >/dev/null 2>&1

subagent_host="$hroot/subagent-host/run-unattended.sh"; mkdir -p "$hroot/subagent-host"
printf '#!/bin/sh\necho "$$"\n"$1"\n' > "$subagent_host"; chmod +x "$subagent_host"
printf '{"name":"agent-11fe5e55","cwd":"%s"}' "$PWD" | "$subagent_host" "$P/hooks/worktree-create.sh" > "$hroot/hook.out" 2>/dev/null
live_host_pid="$(head -1 "$hroot/hook.out")"; live_agent_worktree="$(tail -1 "$hroot/hook.out")"
stale_claim "$live_agent_worktree"; printf '%s\t\t/bin/sh %s\n' "$live_host_pid" "$subagent_host" > "$FLOW_HEALTH_PROCS"
hs > "$hroot/out" 2>&1
check "health: a sub-agent's ad hoc claim is kept while the session that claimed it still runs" [ -f "$live_agent_worktree/.flow/claim.json" ]
: > "$FLOW_HEALTH_PROCS"; "$P/scripts/steward.sh" release "$live_agent_worktree" --force >/dev/null 2>&1

working_agent_worktree="$(printf '{"name":"agent-3a6e17ed","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
stale_claim "$working_agent_worktree"; printf '4646\t%s\tclaude\n' "$working_agent_worktree" > "$FLOW_HEALTH_PROCS"
hs > "$hroot/out" 2>&1
check "health: a sub-agent's ad hoc claim is kept while an agent works in its worktree" [ -f "$working_agent_worktree/.flow/claim.json" ]
: > "$FLOW_HEALTH_PROCS"; "$P/scripts/steward.sh" release "$working_agent_worktree" --force >/dev/null 2>&1

calling_agent_worktree="$(printf '{"name":"agent-5e1fca11","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
stale_claim "$calling_agent_worktree"; python3 -c '
import json, sys
p = sys.argv[1] + "/.flow/claim.json"
d = json.load(open(p)); d.pop("pid", None); json.dump(d, open(p, "w"))' "$calling_agent_worktree"
printf '%s\t%s\tclaude\n' "$$" "$calling_agent_worktree" > "$FLOW_HEALTH_PROCS"
hs > "$hroot/out" 2>&1
check "health: a sub-agent's ad hoc claim with no recorded pid is kept while its session calls health from an ancestor process" [ -f "$calling_agent_worktree/.flow/claim.json" ]
: > "$FLOW_HEALTH_PROCS"; "$P/scripts/steward.sh" release "$calling_agent_worktree" --force >/dev/null 2>&1

fakeloop="$work/fake/run-unattended.sh"; mkdir -p "$work/fake"; printf '#!/bin/sh\nsleep 60\n' > "$fakeloop"; chmod +x "$fakeloop"
loop="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$fakeloop")"
a="$(hitem "Empty claim")"; FLOW_RUN_PID="$loop" "$P/scripts/next.sh" "$a" >/dev/null; wa="$("$P/scripts/steward.sh" find "$a")"
check "next records the pid of the loop that owns the run" [ "$(jget pid < "$(rec "$a")")" = "$loop" ]
age_run "$a" "$loop"; stale_claim "$wa"
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "health: a record whose pid still runs the loop is alive, however old" sh -c "[ -f '$(rec "$a")' ] && [ -f '$wa/.flow/claim.json' ] && grep -q '1 claimed (1 running' '$hroot/out'"
check "board: a live run shows where it runs" sh -c "'$P/scripts/board.sh' | grep -q 'running on'"
pkill -P "$loop" 2>/dev/null; kill "$loop" 2>/dev/null; wait "$loop" 2>/dev/null
check "board: a record with no process is a dead run, not a running one" sh -c "'$P/scripts/board.sh' > '$hroot/board' && grep -q '(dead run)' '$hroot/board' && ! grep -q 'running on' '$hroot/board' && grep -q '^## Health' '$hroot/board' && grep -q 'dead run of implement' '$hroot/board'"
events_before="$(wc -l < .flow/events.log | tr -d ' ')"
hs --dry-run > "$hroot/out" 2>&1
check "health --dry-run: says what it would do and changes nothing" sh -c "grep -q 'would clear the dead run' '$hroot/out' && grep -q 'would release the empty claim' '$hroot/out' && [ -f '$(rec "$a")' ] && [ -f '$wa/.flow/claim.json' ] && [ \"\$(wc -l < .flow/events.log | tr -d ' ')\" = $events_before ]"
"$P/jobs/health.sh" claude >/dev/null
check "health: a dead run's record is cleared and logged" sh -c "[ ! -f '$(rec "$a")' ] && grep -q \"$a: dead run of implement cleared\" .flow/log/health.log && grep -q \"$a	health	dead run of implement cleared\" .flow/events.log"
check "health: an empty claim is released and the item is back with the tracker" sh -c "[ ! -f '$wa/.flow/claim.json' ] && [ -z \"\$('$P/adapters/local/read.sh' '$a' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"].get(\"worktree\",\"\"))')\" ] && [ \"\$(git -C '$wa' symbolic-ref --short HEAD)\" = main-wt-1 ] && grep -q 'released the empty claim' .flow/log/health.log"
check_all "health job: a run that found something says so" 'tail -1 .flow/log/runs.jsonl | grep -q '\''"result":"done: '\'''

b="$(hitem "Has commits")"; wb="$(hold "$b")"; commit_in "$wb" work >/dev/null
age_run "$b"; stale_claim "$wb"; : > "$hroot/host.log"
hs --wait > "$hroot/out" 2>&1
check "health: a dead run with commits is resumed, never released" sh -c "[ -f '$wb/.flow/claim.json' ] && grep -q \"$b: resumed implement on claude (attempt 1 of 3)\" '$hroot/out' && grep -q 'Follow the brief' '$hroot/host.log' && [ \"\$(cat .flow/health/$(item_slug "$b").resume)\" = '1 implement' ]"
check "health: the resumed step's brief says where the dead run stopped" grep -q 'The previous run of step implement died' "$wb/.flow/reports/$(item_slug "$b")/brief-implement.md"
check "health: the resume note goes in that one brief and no later one" sh -c "[ ! -f '$wb/.flow/reports/$(item_slug "$b")/resume.md' ] && ! grep -qs 'previous run' '$wb/.flow/reports/$(item_slug "$b")/health.md'"
check "health: the resumed run logs to its own file, not the health log" sh -c "[ -f .flow/log/resume-$(item_slug "$b").log ] && ! grep -q 'Follow the brief' .flow/log/health.log"
c="$(hitem "Dirty tree")"; wc2="$(hold "$c")"; printf 'unsaved\n' > "$wc2/dirty.txt"
age_run "$c"; stale_claim "$wc2"; : > "$hroot/host.log"
hs --wait > "$hroot/out" 2>&1
check "health: a dirty tree is never released or reset, and its run resumes" sh -c "[ -f '$wc2/.flow/claim.json' ] && [ \"\$(cat '$wc2/dirty.txt')\" = unsaved ] && grep -q \"$c: resumed implement\" '$hroot/out' && grep -q \"$wc2\" '$hroot/host.log'"
d="$(hitem "Idle with commits")"; wd="$(hold "$d")"; commit_in "$wd" idle >/dev/null; rm -f "$(rec "$d")"; stale_claim "$wd"; : > "$hroot/host.log"
hs --wait > "$hroot/out" 2>&1
check "health: a claim with commits and no run is left to the next job" sh -c "[ -f '$wd/.flow/claim.json' ] && [ ! -s '$hroot/host.log' ] && ! grep -q \"$d\" '$hroot/out'"

for i in 2 3; do age_run "$b"; hs --wait > "$hroot/out" 2>&1; done
check "health: a step that keeps dying is resumed up to max_resumes times" [ "$(facts "$b.*resumed implement")" = 3 ]
age_run "$b"; hs --wait > "$hroot/out" 2>&1
check "health: after max_resumes it raises an escalation gate instead of looping" sh -c "[ \"\$('$P/adapters/local/read.sh' '$b' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"gate\"])')\" = escalation ] && [ -f .flow/gates/$(item_slug "$b").json ] && grep -q 'died 3 times in a row' '$hroot/out' && [ $(facts "$b.*resumed implement") = 3 ] && [ -f '$wb/.flow/claim.json' ]"
check "health: the escalation notifies" grep -q "$(printf '\t')escalation$(printf '\t')" .flow/events.log
# The gate says what the dead runs left, so the owner can answer it without reading the logs first.
# What they left is read here from the same log, and the gate must carry that line whole: a killed
# loop most often logs nothing, but a subshell of it that outlives the first kill by a moment can
# get a "Killed" line out, and then the gate quotes that line. The path the gate names is the one
# git resolves, so only its end is checked (a temp folder is a link on macOS).
left="$(python3 -I "$P/scripts/_health.py" died ".flow/log/resume-$(item_slug "$b").log" "$b" implement "$wb/.flow/reports/$(item_slug "$b")/implement.json" "$hroot/no-resume-file")"
check_all "health: the escalation gate says what the dead runs left, and names their log" 'jget message < ".flow/gates/$(item_slug "$b").json" > "$hroot/gate.msg" && [ -n "$left" ] && ! printf "%s" "$left" | grep -q "has no line of this step" && grep -qF "without the step advancing. $left $(basename "$wb") keeps its commits" "$hroot/gate.msg" && grep -q "/app/.flow/log/resume-$(item_slug "$b").log, then clear the gate" "$hroot/gate.msg" && ! grep -q "after the last resume" "$hroot/gate.msg"'
died="$work/died"; mkdir -p "$died"
printf 'run-unattended: t-1 step implement in /wt\nan older run\nrun-unattended: t-1 step implement in /wt\n\nlast\tline one\nlast line two\n' > "$died/log"
printf '3 implement\n' > "$died/resume"; touch -t 202401010000 "$died/resume"; printf '{"status":"done"}' > "$died/implement.json"
python3 -I "$P/scripts/_health.py" died "$died/log" t-1 implement "$died/implement.json" "$died/resume" > "$died/out"
check_all "health: a result written after the last resume, with log lines after it, is said as it is and not as a loop ended from outside" 'grep -q "The last session wrote implement.json (status done) after the last resume, and the step did not advance on it" "$died/out" && ! grep -q "from outside" "$died/out" && grep -q "last lines: last line one / last line two$" "$died/out" && ! grep -q "an older run" "$died/out" && [ "$(wc -l < "$died/out" | tr -d " ")" = 1 ]'
# advance.sh reads the result, then the tracker: a tracker it cannot read ends the loop by itself
# with the record left, which health resumes too. The log then says so, and the gate quotes it.
printf 'run-unattended: t-1 step implement in /wt\nflow: cannot read t-1\nrun-unattended: stopped (exit 1)\n' > "$died/log-advance"
python3 -I "$P/scripts/_health.py" died "$died/log-advance" t-1 implement "$died/implement.json" "$died/resume" > "$died/out"
check_all "health: a loop that ended by itself after the result is not said to be ended from outside" '! grep -q "from outside" "$died/out" && grep -q "last lines: flow: cannot read t-1 / run-unattended: stopped (exit 1)$" "$died/out"'
printf 'run-unattended: t-1 step implement in /wt\n' > "$died/log-silent"
python3 -I "$P/scripts/_health.py" died "$died/log-silent" t-1 implement "$died/implement.json" "$died/resume" > "$died/out"
check_all "health: only a result written after the last resume with a silent log is said as a loop ended from outside" 'grep -q "wrote implement.json (status done) after the last resume, yet the run logged nothing after it started the step" "$died/out" && grep -q "something ended the loop from outside" "$died/out" && ! grep -q "last lines" "$died/out"'
touch -t 202401010000 "$died/implement.json"; touch "$died/resume"
python3 -I "$P/scripts/_health.py" died "$died/log" t-1 test "$died/implement.json" "$died/resume" > "$died/out"
check_all "health: a result older than the last resume is not said, nor a log with no line of the step taken for a silent one" '! grep -q "The last session wrote" "$died/out" && grep -q "has no line of this step" "$died/out" && ! grep -q "logged nothing" "$died/out"'

printf '{"job":"next","at":"2026-10-20T10:00:00Z","seconds":1,"exit":0,"result":"quiet: no free worktree (the pool is at pool_max)"}\n' >> .flow/log/runs.jsonl
: > "$work/offline.log"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a full pool that next cannot start in is said once, with who holds each worktree and why" sh -c "[ \$(grep -c 'the pool is full' .flow/events.log) = 1 ] && [ \$(grep -c 'flow: health' '$work/offline.log') = 1 ] && grep -q 'wt-1 holds $b: waiting at the escalation gate' '$hroot/out' && grep -q 'holds $c: .*dead run, resumed\\|holds $c: running' '$hroot/out' && grep -q 'holds $d: no run' '$hroot/out' && ! grep -q 'the pool is full' '$hroot/out2'"
# A worker whose last runs in a row all waited out the pick lock, or ended as if done without a
# step, is said once per streak, from two runs on, and forgotten once a run ends another way.
printf '{"job":"next-2","at":"2026-10-20T10:00:00Z","seconds":61,"exit":0,"result":"quiet: another worker held the pick for over 60s"}\n' >> .flow/log/runs.jsonl
hs > "$hroot/out" 2>&1
printf '[1]\n{"job":null,"result":7}\n' >> .flow/log/runs.jsonl
check "health: one run that waited out the pick lock is not a streak, and a record that is not one is skipped" sh -c "! grep -q 'waited out the pick lock' '$hroot/out'"
printf '{"job":"next-2","at":"2026-10-20T10:30:00Z","seconds":1,"exit":0,"result":"skipped: run 1 still going"}\n{"job":"next-2","at":"2026-10-20T11:00:00Z","seconds":61,"exit":0,"result":"quiet: another worker held the pick for over 60s"}\n{"job":"next-1","at":"2026-10-20T11:00:00Z","seconds":3,"exit":0,"result":"stopped: no step ran (exit 6: gh#9 is done (every step ran). Merge or close it.)"}\n{"job":"next-1","at":"2026-10-20T11:30:00Z","seconds":3,"exit":0,"result":"stopped: no step ran (exit 6: gh#9 is done (every step ran). Merge or close it.)"}\n' >> .flow/log/runs.jsonl
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a worker that waited out the pick lock twice in a row is said once, a skipped run between does not break the streak" sh -c "grep -q 'next-2 waited out the pick lock on its last 2 runs in a row: another worker held the pick for longer than the lock wait' '$hroot/out' && ! grep -q 'waited out the pick lock' '$hroot/out2'"
check "health: a worker that twice ended without running a step is said once, with its last word" sh -c "grep -q 'next-1 ended without running a step on its last 2 runs in a row (last: stopped: no step ran (exit 6: gh#9 is done' '$hroot/out' && ! grep -q 'without running a step' '$hroot/out2'"
printf '{"job":"next-2","at":"2026-10-20T11:30:00Z","seconds":300,"exit":0,"result":"done, 3 steps"}\n' >> .flow/log/runs.jsonl
hs > "$hroot/out" 2>&1
check "health: a run that did work ends the streak, and it is forgotten" sh -c "! grep -q 'waited out the pick lock' '$hroot/out' && [ ! -f .flow/health/next-lock-next-2.seen ]"
printf '{"job":"next-2","at":"2026-10-20T12:00:00Z","seconds":61,"exit":0,"result":"quiet: another worker held the pick for over 60s"}\n{"job":"next-2","at":"2026-10-20T12:30:00Z","seconds":61,"exit":0,"result":"quiet: another worker held the pick for over 60s"}\n' >> .flow/log/runs.jsonl
hs > "$hroot/out" 2>&1
check "health: a new streak after that is said again" grep -q 'next-2 waited out the pick lock on its last 2 runs in a row' "$hroot/out"

bd="flow/$(item_slug "$d")"
git -C "$wd" push -q origin "$bd"; remote_commit "$bd" r1
hs > "$hroot/out" 2>&1
check "health: a clean branch only behind its remote is fast-forwarded" sh -c "[ \"\$(git -C '$wd' rev-parse HEAD)\" = \"\$(git -C '$hroot/other' rev-parse HEAD)\" ] && grep -q 'fast-forwarded $bd' '$hroot/out'"
commit_in "$wd" l1 >/dev/null
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: by default a branch only ahead of its remote is said once and not pushed" sh -c "[ \"\$(git --git-dir='$hroot/origin.git' rev-parse refs/heads/$bd)\" != \"\$(git -C '$wd' rev-parse HEAD)\" ] && grep -q 'not pushed (jobs.health.push is off)' '$hroot/out' && ! grep -q 'not pushed' '$hroot/out2'"
cp .flow/config.yaml "$hroot/config.yaml"; printf '    push: true\n' >> .flow/config.yaml
hs > "$hroot/out" 2>&1; cp "$hroot/config.yaml" .flow/config.yaml
check "health: with jobs.health.push a clean branch only ahead of an existing remote branch is pushed" sh -c "[ \"\$(git --git-dir='$hroot/origin.git' rev-parse refs/heads/$bd)\" = \"\$(git -C '$wd' rev-parse HEAD)\" ] && grep -q 'pushed 1 commit' '$hroot/out'"
dr="$wd/.flow/reports/$(item_slug "$d")"; : > "$work/offline.log"
remote_commit main m2; remote_commit main m3; remote_commit main m4
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a clean branch far behind its base, with no PR, gets the base merged in and no notification" sh -c "git -C '$wd' merge-base --is-ancestor origin/main HEAD && grep -q 'merged origin/main into $bd (3 commits behind)' '$hroot/out' && ! grep -q 'merged origin/main' '$hroot/out2' && [ ! -f '$dr/sync.md' ] && ! grep -q 'flow: health' '$work/offline.log'"
"$P/adapters/local/write-state.sh" "$d" pr=https://github.com/o/r/pull/9 >/dev/null
remote_commit main m5; remote_commit main m6; remote_commit main m7
hs > "$hroot/out" 2>&1
check "health: a branch with a PR is not merged into: its conflicts are the comments job's" sh -c "! git -C '$wd' merge-base --is-ancestor origin/main HEAD && ! grep -q 'origin/main into $bd\|$bd needs' '$hroot/out' && [ ! -f '$dr/sync.md' ]"
"$P/adapters/local/write-state.sh" "$d" pr= >/dev/null
printf 'mine\n' > "$wd/README.md"; git -C "$wd" commit -qam mine
git -C "$hroot/other" checkout -q -B main origin/main && git -C "$hroot/other" pull -q origin main && printf 'theirs\n' > "$hroot/other/README.md" && git -C "$hroot/other" commit -qam theirs && git -C "$hroot/other" push -q origin main
pre="$(git -C "$wd" rev-parse HEAD)"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a base merge that conflicts is aborted and handed to the sync step, with no notification" sh -c "[ \"\$(git -C '$wd' rev-parse HEAD)\" = '$pre' ] && [ -z \"\$(git -C '$wd' status --porcelain -- . ':!.flow')\" ] && [ \"\$(cat '$dr/sync.md')\" = origin/main ] && grep -q '$bd needs origin/main merged in' '$hroot/out' && ! grep -q 'needs origin/main' '$hroot/out2' && ! grep -q 'flow: health' '$work/offline.log'"
"$P/scripts/next.sh" "$d" >/dev/null
run_step="$(jget step < "$(rec "$d")")"; own="$("$P/adapters/local/read.sh" "$d" | jget state.step)"
check "health: the next run is the sync step, ahead of the item's own step" sh -c "grep -q '## The merge' '$dr/brief-sync.md' && grep -q '^- \`origin/main\`' '$dr/brief-sync.md' && grep -q 'Your own step is implement' '$dr/brief-sync.md' && [ '$run_step' = sync ] && [ '$own' = implement ]"
printf '{"status": "done", "summary": "merged origin/main"}\n' > "$dr/sync.json"
"$P/scripts/advance.sh" "$d" > "$hroot/out" 2>&1; code=$?
own="$("$P/adapters/local/read.sh" "$d" | jget state.step)"
check "health: a finished sync step drops the order and leaves the item on its own step" sh -c "[ $code = 0 ] && grep -q 'sync done -> implement' '$hroot/out' && [ ! -f '$dr/sync.md' ] && [ ! -f '$(rec "$d")' ] && [ '$own' = implement ]"
check "health: a finished sync step puts the item's own step back in the claim" [ "$(jget step < "$wd/.flow/claim.json")" = implement ]
printf 'origin/main\n' > "$dr/sync.md"; "$P/scripts/next.sh" "$d" >/dev/null
printf '{"status": "fail", "summary": "tests red after the merge"}\n' > "$dr/sync.json"; "$P/scripts/advance.sh" "$d" >/dev/null 2>&1; code=$?
gate_now="$("$P/adapters/local/read.sh" "$d" | jget state.gate)"; own="$("$P/adapters/local/read.sh" "$d" | jget state.step)"
check "health: a failed sync step raises an escalation gate and keeps the order" sh -c "[ $code = 4 ] && [ '$gate_now' = escalation ] && [ '$own' = implement ] && [ -f '$dr/sync.md' ]"
"$P/scripts/gate.sh" clear "$d" "retry" >/dev/null 2>&1
commit_in "$wd" l2 >/dev/null; remote_commit "$bd" r2
local_tip="$(git -C "$wd" rev-parse HEAD)"; remote_tip="$(git --git-dir="$hroot/origin.git" rev-parse "refs/heads/$bd")"
hs > "$hroot/out" 2>&1
check "health: a diverged branch goes to the sync step with its remote first, and its history is left alone" sh -c "[ \"\$(head -1 '$dr/sync.md')\" = 'origin/$bd' ] && [ \"\$(tail -1 '$dr/sync.md')\" = origin/main ] && [ \"\$(git -C '$wd' rev-parse HEAD)\" = '$local_tip' ] && [ \"\$(git --git-dir='$hroot/origin.git' rev-parse refs/heads/$bd)\" = '$remote_tip' ]"
side="$(git -C "$wd" commit-tree "HEAD^{tree}" -p HEAD -m side)"; printf '%s\n' "$side" >> "$dr/sync.md"
hs > "$hroot/out" 2>&1
check "health: a rewritten sync note keeps a ref another writer put there that is not merged yet" sh -c "[ \"\$(cat '$dr/sync.md')\" = \"\$(printf 'origin/$bd\norigin/main\n$side')\" ]"

python3 -c '
import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); d["time"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 172800)); json.dump(d, open(p, "w"))' ".flow/gates/$(item_slug "$b").json"
: > "$work/offline.log"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a branch waiting at a gate is not merged into" sh -c "! grep -q 'merged origin/main into flow/$(item_slug "$b")' .flow/events.log"
check "health: a gate waiting past the reminder interval is reminded once" sh -c "grep -q '$b: waiting 2d .* at the escalation gate' '$hroot/out' && ! grep -q 'at the escalation gate' '$hroot/out2' && [ \$(grep -c 'flow: health' '$work/offline.log') = 1 ]"
printf 'escalation 1\n' > ".flow/health/$(item_slug "$b").remind"
hs > "$hroot/out" 2>&1
check "health: the next interval reminds again" grep -q "$b: waiting 2d .* at the escalation gate" "$hroot/out"
waiting_before="$(hs 2>&1 | tail -1 | sed -n 's/.* \([0-9]*\) gate(s) waiting.*/\1/p')"
closed_gate_item="$(hitem "Closed under a gate")"; "$P/scripts/gate.sh" raise "$closed_gate_item" feel-test "Launch it." >/dev/null 2>&1
"$P/adapters/local/close.sh" "$closed_gate_item" >/dev/null
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "HealthGates_GateOnClosedItem_SaidAsADefect: a gate on a closed item is reported as a defect" grep -q "^$closed_gate_item: .*defect" "$hroot/out"
check "HealthGates_GateOnClosedItem_NotCountedAsWaiting: a gate on a closed item is not counted among the gates waiting" sh -c "[ -n '$waiting_before' ] && tail -1 '$hroot/out' | grep -q ' $waiting_before gate(s) waiting'"
check_all "HealthGates_GateOnClosedItem_SaidOnce: the next health run does not repeat the defect while the gate stays" 'grep -q "^$closed_gate_item: .*defect" "$hroot/out" && ! grep -q "^$closed_gate_item: .*defect" "$hroot/out2"'
check_all "GateList_GateOnClosedItem_NamesTheItem: gate.sh list names the closed item's gate before the drop" 'gates="$("$P/scripts/gate.sh" list)" && printf "%s\n" "$gates" | grep -q "	$closed_gate_item	"'
"$P/scripts/gate.sh" drop "$closed_gate_item" closed >/dev/null 2>&1
check_all "GateDrop_GateOnClosedItem_ListNamesNoGate: gate.sh list names no gate of the item once its gate is dropped" 'gates="$("$P/scripts/gate.sh" list)" && ! printf "%s\n" "$gates" | grep -q "	$closed_gate_item	"'

rm -f "$wc2/dirty.txt"; "$P/scripts/steward.sh" release "$c" --force >/dev/null 2>&1
e="$(hitem "No remote branch")"; we="$(hold "$e")"; commit_in "$we" solo >/dev/null; rm -f "$(rec "$e")"; stale_claim "$we"
hs > "$hroot/out" 2>&1
check "health: a task branch with no remote counterpart is never pushed" sh -c "[ -z \"\$(git ls-remote --heads origin 'flow/$(item_slug "$e")')\" ] && [ -f '$we/.flow/claim.json' ]"
hs > "$hroot/out" 2>&1
check "health: a state it already said is not said again" grep -q 'nothing to do' "$hroot/out"
der="$we/.flow/reports/$(item_slug "$e")"; mkdir -p "$der"
git -C "$we" rev-parse HEAD~1 > "$der/sync.md"
hs --dry-run > "$hroot/out" 2>&1
check "health --dry-run: a sync note whose refs are merged is only said, and kept" sh -c "[ -f '$der/sync.md' ] && grep -q 'would clear the sync note' '$hroot/out'"
hs > "$hroot/out" 2>&1
check "health: a sync note written by another hand whose refs are all merged is removed, and said" sh -c "[ ! -f '$der/sync.md' ] && grep -q \"$e: cleared the sync note for flow/$(item_slug "$e"): every ref it names is merged in\" '$hroot/out'"
git -C "$we" commit-tree "HEAD^{tree}" -p HEAD -m side > "$der/sync.md"; cp "$der/sync.md" "$hroot/note"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a sync note with a ref not merged yet is kept across runs, and nothing is said" sh -c "cmp -s '$der/sync.md' '$hroot/note' && ! grep -q 'sync note' '$hroot/out' '$hroot/out2'"
printf 'console/gone\n' > "$der/sync.md"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a sync note with a ref that does not resolve is kept and said once" sh -c "[ \"\$(cat '$der/sync.md')\" = console/gone ] && grep -q 'names console/gone which does not resolve' '$hroot/out' && ! grep -q 'sync note' '$hroot/out2'"
rm -f "$der/sync.md"
"$P/scripts/next.sh" "$e" >/dev/null; age_run "$e" -
printf '4242\t\tclaude -p Follow the brief. Work in %s.\n' "$we" > "$FLOW_HEALTH_PROCS"
hs --wait > "$hroot/out" 2>&1
check "health: a record with no pid is alive while a process names its worktree" sh -c "[ -f '$(rec "$e")' ] && ! grep -q 'dead run' '$hroot/out'"
printf '7671\t\tclaude daemon run --spawned-by {"cwd":"%s"}\n4243\t\tvim %s/README.md\n4244\t\ttail -f %s/log\n' "$we" "$we" "$we" > "$FLOW_HEALTH_PROCS"
hs --wait > "$hroot/out" 2>&1
check "health: the same record is a dead run once only a daemon, an editor or a tail names it" grep -q "$e: dead run of implement cleared" "$hroot/out"
: > "$FLOW_HEALTH_PROCS"
# The Codex desktop app's servers keep the folder they started in for days: never a session there.
printf '7672\t%s\t/x/bin/codex app-server --listen unix:// --managed-daemon\n7673\t%s\t/x/bin/codex app-server daemon pid-update-loop\n7674\t%s\t/x/codex -c features.a=true app-server\n7675\t%s\t/x/codex exec-server\n' "$we" "$we" "$we" "$we" > "$FLOW_HEALTH_PROCS"
check "alive: the Codex app's app-server, its daemon and exec-server in a worktree are not a session there" [ -z "$(python3 "$P/scripts/_health.py" alive "$FLOW_HEALTH_PROCS" "$e" "$we")" ]
printf '7676\t%s\t/x/bin/codex -c features.a=true\n' "$we" > "$FLOW_HEALTH_PROCS"
check "alive: a Codex session in a worktree, an option before no subcommand, is one" [ "$(python3 "$P/scripts/_health.py" alive "$FLOW_HEALTH_PROCS" "$e" "$we")" = "process 7676" ]
# A prompt that starts with a server word is still an unattended run, never the host's server.
printf '7679\t%s\t/x/bin/claude -p mcp configuration is broken --permission-mode auto\n' "$we" > "$FLOW_HEALTH_PROCS"
check "alive: claude -p whose prompt starts with mcp is a run" [ "$(python3 "$P/scripts/_health.py" alive "$FLOW_HEALTH_PROCS" "$e" "$we")" = "process 7679" ]
printf '7680\t%s\t/x/bin/codex exec daemon crashes on startup\n' "$we" > "$FLOW_HEALTH_PROCS"
check "alive: codex exec whose prompt starts with daemon is a run" [ "$(python3 "$P/scripts/_health.py" alive "$FLOW_HEALTH_PROCS" "$e" "$we")" = "process 7680" ]
printf '7677\t%s\t/x/bin/claude mcp serve\n' "$we" > "$FLOW_HEALTH_PROCS"
check "alive: Claude's MCP server in a worktree is not a session there" [ -z "$(python3 "$P/scripts/_health.py" alive "$FLOW_HEALTH_PROCS" "$e" "$we")" ]
# ps prints a command unquoted, and the desktop app keeps its CLI under Application Support.
printf '7678\t%s\t/Users/x/Library/Application Support/Claude/claude-code/2.1.308/a93d/claude.app/Contents/MacOS/claude --output-format stream-json\n' "$we" > "$FLOW_HEALTH_PROCS"
check "alive: a Claude desktop session, its CLI under a path with a space, is one" [ "$(python3 "$P/scripts/_health.py" alive "$FLOW_HEALTH_PROCS" "$e" "$we")" = "process 7678" ]
# A host session that calls health from a child shell, as the health job runs under one: started as
# claude, it lists itself working in the worktree, then asks alive or owner.
cat > "$work/host-calls-alive" <<'SH'
printf '%s\t%s\tclaude\n' "$$" "$2" > "$3"
sh -c 'printf "[%s]" "$(python3 -I "$1" alive "$3" local:task/none "$2")"' sh "$1" "$2" "$3"
SH
cat > "$work/host-calls-owner" <<'SH'
python3 -I "$1" owner
echo "$$"
SH
self_alive="$(PATH="$refused_ps:$PATH" bash -c 'exec -a claude sh "$@"' sh "$work/host-calls-alive" "$P/scripts/_health.py" "$we" "$hroot/procs-self")"
check "AliveWhereNoPsRuns_SkipsTheHostItRunsUnder: the walk up reads each parent without ps, so health's own session is no run" \
  [ "$self_alive" = "[]" ]
owner_lines="$(PATH="$refused_ps:$PATH" bash -c 'exec -a claude sh "$@"' sh "$work/host-calls-owner" "$P/scripts/_health.py")"
owner_found="$(echo "$owner_lines" | sed -n 1p)"; owner_host="$(echo "$owner_lines" | sed -n 2p)"
check_all "OwnerWhereNoPsRuns_IsTheHostSessionAbove: next.sh records it as the run's pid, which health reads to keep a live run" \
  '[ -n "$owner_host" ] && [ "$owner_found" = "$owner_host" ]'
# A stale session: Claude's status file says idle for 3 days. A stand-in process gives ps a real pid.
sleep 300 & idler=$!
mkdir -p "$HOME/.claude/sessions"
idle_file() { # idle_file <status> <seconds ago> [<cwd>]
  python3 -c 'import json, sys, time; now = time.time(); json.dump({"pid": int(sys.argv[1]), "cwd": sys.argv[4], "startedAt": int(now * 1000), "status": sys.argv[2], "statusUpdatedAt": int((now - int(sys.argv[3])) * 1000)}, open(sys.argv[5], "w"))' \
    "$idler" "$1" "$2" "${3:-$we}" "$HOME/.claude/sessions/$idler.json"
}
idle_file idle 259300
printf '%s\t%s\tclaude\n' "$idler" "$we" > "$FLOW_HEALTH_PROCS"
check "session: a Claude session idle for days is named with how long" [ "$(python3 "$P/scripts/_health.py" session "$FLOW_HEALTH_PROCS" "$idler")" = "claude process $idler, idle 3d 0h" ]
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a session idle past stale_session in a claimed worktree is said once, with what it holds and its kill command" sh -c "grep -q 'pool: stale session: claude process $idler (session) in $(basename "$we") is idle 3d 0h; it holds $e, so the comments job skips that PR while it runs. End it if nobody uses it: kill $idler' '$hroot/out' && ! grep -q 'stale session' '$hroot/out2'"
check "health: the stale session reaches events.log" grep -q "	health	stale session: claude process $idler" .flow/events.log
"$P/scripts/steward.sh" sessions > "$hroot/out" 2>&1
check "sessions: lists the session with its worktree, item, idle time and kill command" sh -c "grep -q '^$idler  *claude  *session  *$(basename "$we")  *$e  *idle 3d 0h  *STALE: kill $idler\$' '$hroot/out'"
cp .flow/config.yaml "$hroot/config.yaml"; printf '    stale_session: 4d\n' >> .flow/config.yaml
check "sessions --stale: a session idle less than stale_session is left out" sh -c "! '$P/scripts/steward.sh' sessions --stale | grep -q '^$idler '"
hs > "$hroot/out" 2>&1; cp "$hroot/config.yaml" .flow/config.yaml
check "health: a session no longer stale lets its mark go, so the next streak is said again" [ ! -f .flow/health/stale-session-$idler.seen ]
idle_file busy 259300
check "sessions: a busy session is never stale" sh -c "'$P/scripts/steward.sh' sessions | grep -q '^$idler .* busy *\$'"
idle_file idle 259300 /elsewhere
check "session: a status file for another folder is an earlier process's, so no idle time is read" [ "$(python3 "$P/scripts/_health.py" session "$FLOW_HEALTH_PROCS" "$idler" | sed 's/running .*/running/')" = "claude process $idler, running" ]
kill "$idler" 2>/dev/null; wait "$idler" 2>/dev/null; rm -f "$HOME/.claude/sessions/$idler.json"
: > "$FLOW_HEALTH_PROCS"
hs --wait > "$hroot/out" 2>&1
check "health: a record younger than the grace is left alone, whatever its pid" sh -c "[ -f '$(rec "$e")' ] && [ $(facts "$e.*resumed implement") = 1 ]"
rm -f "$wd/.flow/reports/$(item_slug "$d")/sync.md"; "$P/scripts/steward.sh" release "$d" --force >/dev/null 2>&1
g="$(hitem "Empty at a gate")"; wg="$(hold "$g")"; "$P/scripts/gate.sh" raise "$g" ambiguity "Which one?" >/dev/null 2>&1; stale_claim "$wg"
hs > "$hroot/out" 2>&1
check "health: an empty claim waiting at a gate is not released" sh -c "[ -f '$wg/.flow/claim.json' ] && ! grep -q 'released the empty claim' '$hroot/out'"
"$P/scripts/gate.sh" clear "$g" answered >/dev/null 2>&1; stale_claim "$wg"
grep -v "$(printf '\t')$g$(printf '\t')" .flow/events.log > "$hroot/events" || true; cp "$hroot/events" .flow/events.log
(cd "$wg" && exec bash -c 'exec -a claude sleep 30') >/dev/null 2>&1 & agent=$!
sleep 1
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "health: an empty claim with an agent working in its worktree is not released" sh -c "[ -f '$wg/.flow/claim.json' ] && ! grep -q 'released the empty claim' '$hroot/out'"
PATH="$refused_ps:$PATH" env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "HealthWhereNoPsRuns_ListsTheAgentInTheClaim: pgrep lists the processes, so health judges the claim instead of leaving every run unjudged" \
  sh -c "[ -f '$wg/.flow/claim.json' ] && ! grep -q 'cannot list processes' '$hroot/out'"
kill "$agent" 2>/dev/null; wait "$agent" 2>/dev/null
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "health: the same claim is released once the agent is gone" sh -c "[ ! -f '$wg/.flow/claim.json' ] && grep -q 'released the empty claim' '$hroot/out'"
h="$(hitem "No ps")"; wh="$(hold "$h")"; age_run "$h"; stale_claim "$wh"
mkdir -p "$work/nops"; printf '#!/bin/sh\nexit 1\n' > "$work/nops/ps"; chmod +x "$work/nops/ps"
PATH="$work/nops:$PATH" env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "health: with no process list no run is judged dead and no claim is released" sh -c "[ -f '$(rec "$h")' ] && [ -f '$wh/.flow/claim.json' ] && grep -q 'cannot list processes' '$hroot/out' && ! grep -q 'dead run\\|released\\|resumed' '$hroot/out'"
rm -f "$(rec "$h")"; "$P/scripts/steward.sh" release "$h" --force >/dev/null 2>&1
# stop and resume: the owner's hand on one item's run.
stoploop="$work/fake/stop/run-unattended.sh"; mkdir -p "$work/fake/stop"; printf '#!/bin/sh\nsleep 60 &\nwait\n' > "$stoploop"; chmod +x "$stoploop"
s="$(hitem "Stopped by hand")"; ws="$(hold "$s")"; printf 'kept\n' > "$ws/wip.txt"
loop="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$stoploop")"; sleep 1; loopchild="$(pgrep -P "$loop")"
age_run "$s" "$loop"; : > "$hroot/host.log"
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" resume "$s" > "$hroot/out" 2>&1; code=$?
check "resume: a run whose process is alive is refused, exit 1, and left as it is" sh -c "[ $code = 1 ] && grep -q 'the run of implement is still alive (pid $loop): end it first with steward.sh stop $s' '$hroot/out' && [ -f '$(rec "$s")' ] && kill -0 $loop && [ ! -s '$hroot/host.log' ]"
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" stop "$s" > "$hroot/out" 2>&1; code=$?
sleep 1
check "stop: ends the run's process and every one under it, and removes its record" sh -c "[ $code = 0 ] && [ -n '$loopchild' ] && ! kill -0 $loop 2>/dev/null && ! kill -0 $loopchild 2>/dev/null && [ ! -f '$(rec "$s")' ] && grep -q '$s: run of implement stopped by the owner: 2 process(es) ended' '$hroot/out'"
check "stop: keeps the claim, the worktree and its changes, and says so in events.log and last_event" sh -c "[ -f '$ws/.flow/claim.json' ] && [ \"\$(cat '$ws/wip.txt')\" = kept ] && grep -q '	$s	stopped	run of implement stopped by the owner\$' .flow/events.log && '$P/adapters/local/read.sh' '$s' | grep -q 'run of implement stopped by the owner'"
wait "$loop" 2>/dev/null
check "stop: an item with no run in flight is said, exit 0" sh -c "'$P/scripts/steward.sh' stop '$s' | grep -q '$s: no run in flight, nothing to stop'"
check "stop: a malformed item is refused, exit 2" sh -c "'$P/scripts/steward.sh' stop 'gh#x' 2>/dev/null; [ \$? = 2 ]"
check "resume: an item with no run record is refused, exit 1" sh -c "'$P/scripts/steward.sh' resume '$s' 2>&1 | grep -q '$s has no run record'; '$P/scripts/steward.sh' resume '$s' >/dev/null 2>&1; [ \$? = 1 ]"
"$P/scripts/next.sh" "$s" >/dev/null; age_run "$s"; : > "$hroot/host.log"
check "resume: an --effort the host does not take is refused, exit 2, and the record stays" sh -c "env -u FLOW_HEALTH_PROCS '$P/scripts/steward.sh' resume '$s' --host codex --effort max 2>&1 | grep -q 'codex takes low, medium, high or xhigh'; [ -f '$(rec "$s")' ] && [ ! -s '$hroot/host.log' ]"
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" resume "$s" --wait --model claude-resume-z --effort low > "$hroot/out" 2>&1; code=$?
check "resume: --model and --effort reach the resumed step with no agent" grep -q -- '--model claude-resume-z --effort low' "$hroot/host.log"
check "resume: a dead run is cleared and its step starts again, as the health job resumes one" sh -c "[ $code = 0 ] && grep -q '$s: resumed implement on claude (attempt 1 of 3)' '$hroot/out' && grep -q 'Follow the brief' '$hroot/host.log' && grep -q '^$ws	' '$hroot/host.log' && [ \"\$(cat .flow/health/$(item_slug "$s").resume)\" = '1 implement' ] && grep -q '	$s	resume	dead run of implement cleared by the owner' .flow/events.log"
check "resume: the resumed step's brief carries the health job's note" grep -q 'The previous run of step implement died' "$ws/.flow/reports/$(item_slug "$s")/brief-implement.md"
rm -f "$(rec "$s")" "$ws/wip.txt" ".flow/health/$(item_slug "$s").resume"; "$P/scripts/steward.sh" release "$s" --force >/dev/null 2>&1
"$P/scripts/jobs.sh" pause health >/dev/null; : > .flow/events.log
"$P/jobs/health.sh" claude | grep -q paused
check "health job: a paused job does nothing" [ ! -s .flow/events.log ]
"$P/scripts/jobs.sh" resume health >/dev/null
check "jobs: status lists the health job with its schedule" sh -c "'$P/scripts/jobs.sh' status | grep -q '^| health | every 15m'"
check "jobs: cron gets the health line" sh -c "FLOW_SCHEDULER=cron '$P/scripts/jobs.sh' install health | grep -q '^\*/15 \* \* \* \* .*\.flow/jobs/health\.sh claude'"
check "jobs: history and logs take the health job" sh -c "'$P/scripts/jobs.sh' history health 3 | grep -q 'quiet\|work' && '$P/scripts/jobs.sh' logs health 3 | grep -q 'health.log'"
check "health job: an --effort its host does not take is refused, exit 2" sh -c "'$P/jobs/health.sh' codex --effort max 2>/dev/null; [ \$? = 2 ]"
printf '{"job":"health","at":"2026-10-24T10:00:00Z","seconds":1,"exit":0,"result":42}\n' >> .flow/log/runs.jsonl
check_all "jobs: a run recorded before 1.20.2 with a result of digits (a number) still shows in status and history" '"$P/scripts/jobs.sh" status >/dev/null && "$P/scripts/jobs.sh" status --json >/dev/null && "$P/scripts/jobs.sh" history health 3 | grep -q 42'
printf '[1]\n{"job":null,"result":7}\n' >> .flow/log/runs.jsonl
check "jobs: a line in the run history that is not a record is skipped by status and history, not a crash" sh -c "'$P/scripts/jobs.sh' status | grep -q '^| health ' && '$P/scripts/jobs.sh' history health | grep -q health"
unset FLOW_HEALTH_PROCS
cd "$repo"

echo "health: planned holds"
hhroot="$work/holds"; mkdir -p "$hhroot" && cd "$hhroot" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init
for n in 1 2 3; do git worktree add -q -b "main-wt-$n" "../hwt-$n"; done
mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../hwt-1\n  - ../hwt-2\n  - ../hwt-3\nnotify:\n  desktop: true\n' > .flow/config.yaml
export FLOW_HEALTH_PROCS="$hhroot/procs"; : > "$FLOW_HEALTH_PROCS"
hnew() { "$P/adapters/local/create.sh" task "$1" --size S --body x; }
hw() { "$P/adapters/local/write-state.sh" "$@" >/dev/null; }
hheld() { "$P/adapters/local/read.sh" "$1" | jget state.held_by; }
# held_line <seconds ago> <item> <holder> <reason>: the line the hold writer appends to events.log.
held_line() { printf '%s\t%s\theld\tbehind %s: %s\n' "$(python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$1")" "$2" "$3" "$4" >> .flow/events.log; }
h1="$(hnew "Holder, claimed")"; hw "$h1" "changes=src/a/**"
"$P/scripts/steward.sh" claim "$h1" >/dev/null
ha="$(hnew "Valid hold")"; hw "$ha" "changes=src/a/x.cs" "held_by=$h1" "held_reason=both change src/a"; held_line 3600 "$ha" "$h1" "both change src/a"
hb="$(hnew "Changes apart")"; hw "$hb" "changes=src/b/**" "held_by=$h1" "held_reason=was src/a"; held_line 3600 "$hb" "$h1" "was src/a"
hc="$(hnew "Held by itself")"; hw "$hc" "changes=src/c/**" "held_by=$hc" "held_reason=self"
hk="$(hnew "Closed holder")"; hw "$hk" "changes=src/d/**"; "$P/adapters/local/close.sh" "$hk" >/dev/null
hd="$(hnew "Behind a closed one")"; hw "$hd" "changes=src/d/x" "held_by=$hk" "held_reason=src/d"
he="$(hnew "Behind a missing one")"; hw "$he" "changes=src/e/x" "held_by=local:task/99" "held_reason=src/e"
h2="$(hnew "Holder with no claim and no run")"; hw "$h2" "changes=src/f/**"
hf="$(hnew "Behind an idle one")"; hw "$hf" "changes=src/f/x" "held_by=$h2" "held_reason=src/f"
h3="$(hnew "Holder with a run")"; hw "$h3" "changes=src/g/**"
mkdir -p .flow/runs && printf '{"item":"%s","step":"implement","started":"%s"}\n' "$h3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > ".flow/runs/$(item_slug "$h3").json"
hg="$(hnew "Waits long")"; hw "$hg" "changes=src/g/x" "held_by=$h3" "held_reason=both change src/g"; held_line 108000 "$hg" "$h3" "both change src/g"
hx="$(hnew "Cycle, older")"; hy="$(hnew "Cycle, newer")"
"$P/scripts/steward.sh" claim "$hx" >/dev/null; "$P/scripts/steward.sh" claim "$hy" >/dev/null
hw "$hx" "changes=src/h/**" "held_by=$hy" "held_reason=src/h"; held_line 7200 "$hx" "$hy" "src/h"
hw "$hy" "changes=src/h/y" "held_by=$hx" "held_reason=src/h"; held_line 3600 "$hy" "$hx" "src/h"
h4="$(hnew "Holder with touches, no changes")"; hw "$h4" "touches=src/t/**"
printf '{"item":"%s","step":"implement","started":"%s"}\n' "$h4" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > ".flow/runs/$(item_slug "$h4").json"
ht="$(hnew "Behind a bugfix")"; hw "$ht" "changes=src/t/x" "held_by=$h4" "held_reason=both change src/t"; held_line 3600 "$ht" "$h4" "both change src/t"
h5="$(hnew "Holder with nothing recorded")"
printf '{"item":"%s","step":"implement","started":"%s"}\n' "$h5" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > ".flow/runs/$(item_slug "$h5").json"
hn="$(hnew "Behind one with nothing recorded")"; hw "$hn" "changes=src/n/x" "held_by=$h5" "held_reason=src/n"; held_line 3600 "$hn" "$h5" "src/n"
ho="$(hnew "Undated hold")"; hw "$ho" "changes=src/a/o" "held_by=$h1" "held_reason=src/a too"
events_before="$(wc -l < .flow/events.log | tr -d ' ')"
"$P/scripts/steward.sh" health --dry-run > "$hhroot/out" 2>&1
check_all "health --dry-run: says which holds it would clear and clears none" 'grep -q "^$hb: would clear its hold behind $h1: " "$hhroot/out" && [ "$(hheld "$hb")" = "$h1" ] && [ "$(wc -l < .flow/events.log | tr -d " ")" = "$events_before" ]'
: > "$work/offline.log"
"$P/scripts/steward.sh" health > "$hhroot/out" 2>&1
unheld() { grep -q "	$1	unheld	no longer held behind $2: $3\$" .flow/events.log; }
check_all "health: a hold whose holder's changes no longer share a path is cleared, with an unheld line" '[ -z "$(hheld "$hb")" ] && [ -z "$("$P/adapters/local/read.sh" "$hb" | jget state.held_reason)" ] && unheld "$hb" "$h1" "the changes of $h1 no longer share a path with its own" && grep -q "^$hb: no longer held behind $h1" "$hhroot/out"'
check_all "health: a hold on the item itself is cleared" '[ -z "$(hheld "$hc")" ] && unheld "$hc" "$hc" "it was held behind itself"'
check_all "health: a hold behind a closed item stays for next.sh to release with its merge note" '[ "$(hheld "$hd")" = "$hk" ] && ! grep -q "	$hd	unheld	" .flow/events.log && ! grep -q "^$hd:" "$hhroot/out"'
check_all "health: a hold behind an item that cannot be read or found is cleared" '[ -z "$(hheld "$he")" ] && unheld "$he" "local:task/99" "local:task/99 cannot be read or found on the tracker"'
check_all "health: a hold behind an item with no worktree and no run is cleared" '[ -z "$(hheld "$hf")" ] && unheld "$hf" "$h2" "$h2 holds no worktree and has no run"'
check_all "health: in a cycle the newest hold goes and the older one stays" '[ -z "$(hheld "$hy")" ] && [ "$(hheld "$hx")" = "$hy" ] && unheld "$hy" "$hx" "a cycle: $hx waits behind it in turn, and this hold is the newest"'
check_all "health: a holder with no changes is judged by its touches, as hold.sh candidates does, so its hold stays" '[ "$(hheld "$ht")" = "$h4" ] && ! grep -q "^$ht:" "$hhroot/out"'
check_all "health: a holder that records neither changes nor touches keeps its hold, as nothing says they parted" '[ "$(hheld "$hn")" = "$h5" ] && ! grep -q "^$hn:" "$hhroot/out"'
check_all "health: a valid hold under a day stays, unsaid" '[ "$(hheld "$ha")" = "$h1" ] && ! grep -q "^$ha:" "$hhroot/out"'
check_all "health: a hold behind an item with a run stays; past a day it is a finding with its age and reason, notified" '[ "$(hheld "$hg")" = "$h3" ] && grep -q "^$hg: has waited 30h behind $h3: both change src/g\$" "$hhroot/out" && grep -q "flow: health" "$work/offline.log"'
check_all "health: a valid hold no held line dates counts as old" '[ "$(hheld "$ho")" = "$h1" ] && grep -q "^$ho: has waited behind $h1 since before events.log dates it: src/a too\$" "$hhroot/out"'
check "health: each clear and finding counts in the summary" grep -q "7 finding(s)" "$hhroot/out"
"$P/scripts/steward.sh" health > "$hhroot/out" 2>&1
check_all "health: an old hold is said once while it stays, and nothing is cleared twice" '! grep -q "has waited" "$hhroot/out" && ! grep -q "no longer held" "$hhroot/out" && grep -q "nothing to do" "$hhroot/out"'
hw "$hg" held_by= held_reason=
"$P/scripts/steward.sh" health >/dev/null 2>&1
check "health: a hold that went is forgotten, so a new one is said again" sh -c "[ ! -f .flow/health/held-old-$(item_slug "$hg").seen ] && [ -f .flow/health/held-old-$(item_slug "$ho").seen ]"
unset FLOW_HEALTH_PROCS
cd "$repo"

# --- init: stamp, guard, session-start nudge (on a copy of the plugin, so the plugin can change). The fake gh stays on PATH; init tolerates it.
. "$here/_init_fixture.sh"
check "init: a fresh install writes the stamp" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && grep -q '^source	' .flow/stamp && grep -qF '	$codex_rules' .flow/stamp && ! grep -q 'notify.sh' .flow/stamp"
check "init: --check is clean after install" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
check "init: the fresh config has an empty model and effort pair per host, and no old jobs.model" sh -c "for k in claude.model claude.effort codex.model codex.effort; do grep -q \"^  \${k%%.*}:\" .flow/config.yaml || exit 1; [ -z \"\$(. '$P/lib/flow.sh'; yaml_get .flow/config.yaml jobs.\$k)\" ] || exit 1; done; ! grep -q '^  model:' .flow/config.yaml && grep -q 'Empty means the host.s own default' .flow/config.yaml"
cp .flow/config.yaml "$work/fresh.config"
sed -i.bak '/^  claude:$/,/^    effort:/d; /^  codex:$/,/^    effort:/d' .flow/config.yaml && rm -f .flow/config.yaml.bak
check "init: --check does not ask for the jobs.<host> keys on an existing project" sh -c "! grep -q '^  claude:' .flow/config.yaml && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
awk '{ print } /^jobs:$/ { print "  host: vim"; print "  model: opus"; print "  effort: high" }' .flow/config.yaml > "$work/cfg.tmp" && cp "$work/cfg.tmp" .flow/config.yaml
hostline="$(grep -n '^  host: vim' .flow/config.yaml | cut -d: -f1)"
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init.out" 2>&1; code=$?
check "init: --check flags a jobs.host other than claude or codex as drift, with its line" sh -c "[ $code = 1 ] && grep -q 'gap: .flow/config.yaml:$hostline: jobs.host is vim; it must be claude or codex' '$work/init.out'"
check "init: --check says once that jobs.model and jobs.effort are deprecated" [ "$(grep -c 'jobs.model and jobs.effort are deprecated' "$work/init.out")" = 1 ]
sed -i.bak 's/^  host: vim$/  host: codex/; s/^  effort: high$/  effort: max/' .flow/config.yaml && rm -f .flow/config.yaml.bak
check "init: --check flags an effort the jobs host does not take" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'gap: .flow/config.yaml:[0-9]*: jobs.effort is max; codex takes low, medium, high or xhigh'"
cp "$work/fresh.config" .flow/config.yaml
check "init: the fresh config says the lessons log stays on this machine and offers no retro key" sh -c "grep -q 'lessons log .* stays on this machine under .flow/' .flow/config.yaml && ! grep -q '^#* *retro:' .flow/config.yaml"
printf 'retro:\n  commit: false\n' >> .flow/config.yaml
cp .flow/config.yaml "$work/retro.config"
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/retro-check.out" 2>&1
check "InitCheck_RetroCommitSet_ListsItsRemovalAsPendingDrift" grep -q 'drift: .flow/config.yaml: pending migration: retro.commit	' "$work/retro-check.out"
check "InitCheck_RetroCommitSet_LeavesTheConfigUnchanged" cmp -s "$work/retro.config" .flow/config.yaml
cp "$work/fresh.config" .flow/config.yaml
check "init: installs the health job wrapper and its default schedule" sh -c "[ -x .flow/jobs/health.sh ] && [ \"\$(. '$P/lib/flow.sh'; yaml_get .flow/config.yaml jobs.schedule.health)\" = 'every 15m' ] && grep -q 'health: true' .flow/config.yaml"
mkdir -p .flow/answers.lock .flow/health && echo $$ > .flow/answers.lock/pid && echo '{}' > .flow/health/last.json
check "init: the exclude block covers the state folders and the lock directories, so git sees none of them" sh -c "[ -z \"\$(git status --porcelain --untracked-files=all)\" ] && [ ! -e .gitignore ]"
rm -rf .flow/answers.lock .flow/health
sed -i.bak '/^\.flow\/$/d' .git/info/exclude && rm -f .git/info/exclude.bak
check "init: --check reads the block from .git/info/exclude and names one that lacks .flow/" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'drift: .*/.git/info/exclude: the flow block lacks .flow/'"
check "init: a refresh puts .flow/ back in the exclude block" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && grep -qxF '.flow/' .git/info/exclude && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
check "init: the fresh config asks codex and claude for reviews" [ "$(FLOW_PLUGIN="$plugin_copy" "$plugin_copy/scripts/comments.sh" reviewers | tr '\n' ' ')" = "codex claude " ]
check "session-start: silent when the stamp matches" sh -c "[ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
printf '# mine\n' >> .flow/notify.sh
check "init: a wrapper is replaced without a guard" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && ! grep -q '# mine' .flow/notify.sh"
check "init: no wrapper holds the plugin path" sh -c "! grep -rqF '$plugin_copy' .flow/plugin.sh .flow/notify.sh .flow/run-unattended.sh .flow/jobs .flow/hooks"
fake_flow() { # fake_flow <home> <host dir> <version>: a stub flow whose scripts print the version
  d="$1/$2/plugins/cache/m/flow/$3"; mkdir -p "$d/scripts" "$d/jobs" "$d/hooks"
  for f in scripts/next.sh scripts/notify.sh jobs/next.sh hooks/worktree-create.sh; do printf '#!/bin/sh\necho %s\n' "$3" > "$d/$f"; chmod +x "$d/$f"; done
}
fake_flow "$work/h1" .claude 1.9.0; fake_flow "$work/h1" .claude 1.10.0; fake_flow "$work/h1" .codex 2.0.0
fake_flow "$work/h2" .codex 1.4.0
check "plugin.sh: the newest Claude version wins (1.10.0 over 1.9.0)" [ "$(env -u FLOW_PLUGIN HOME="$work/h1" .flow/notify.sh)" = "1.10.0" ]
check "plugin.sh: the job and hook wrappers find it too" sh -c "[ \"\$(env -u FLOW_PLUGIN HOME='$work/h1' .flow/jobs/next.sh)\" = 1.10.0 ] && [ \"\$(env -u FLOW_PLUGIN HOME='$work/h1' .flow/hooks/worktree-create.sh)\" = 1.10.0 ]"
check "plugin.sh: the Codex cache when Claude has none" [ "$(env -u FLOW_PLUGIN HOME="$work/h2" .flow/notify.sh)" = "1.4.0" ]
check "plugin.sh: FLOW_PLUGIN wins" [ "$(FLOW_PLUGIN="$work/h2/.codex/plugins/cache/m/flow/1.4.0" HOME="$work/h1" .flow/notify.sh)" = "1.4.0" ]
mkdir -p "$work/h3"; env -u FLOW_PLUGIN HOME="$work/h3" .flow/notify.sh >/dev/null 2>&1; code=$?
check "plugin.sh: no installed plugin exits 2" [ "$code" -eq 2 ]
before="$(head -1 .flow/stamp)"
sed -i.bak 's/"version": "[^"]*"/"version": "9.9.9"/' "$plugin_copy/.claude-plugin/plugin.json" && rm -f "$plugin_copy/.claude-plugin/plugin.json.bak"
check "a version bump alone: the stamp source holds and session-start is silent" sh -c "[ \"\$(FLOW_PLUGIN='$plugin_copy' '$init' --source-hash)\" = \"\$(printf '%s' '$before' | cut -f2)\" ] && [ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
printf '# mine\n' >> "$codex_rules"
check "init: --check names a hand edit" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -qF 'edited by hand: $codex_rules'"
check "init: refuses to replace a hand edit (exit 1, file kept)" sh -c "! FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && grep -q '# mine' '$codex_rules'"
check "init: --force replaces it" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --force >/dev/null && ! grep -q '# mine' '$codex_rules' && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
printf '\n# changed\n' >> "$plugin_copy/templates/flow.rules"
check "session-start: nudges when the plugin changed" sh -c "echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'behind flow v' && echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -qF 'drift: $codex_rules'"
check "init: refresh brings the stamp back in step" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && [ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"

[ "$fails" -eq 0 ] && { echo "health: ok"; exit 0; }
echo "health: $fails failed"; exit 1

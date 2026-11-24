#!/bin/sh
# pick.sh: auto_gates and the pick: a full pool, an item with nothing to run, holds, parallel
# runs with the pick lock, the pick filters, and every read of the local tracker.
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
. "$here/_stale_pick_fixture.sh"
echo "auto_gates"
mkdir -p "$work/auto" && cd "$work/auto" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 2\nauto_gates:\n  plan-approval: S, M\nnotify:\n  desktop: false\n' > .flow/config.yaml
a1="$("$P/scripts/new.sh" task "Auto plan" --size M --body "## Acceptance
- [ ] x")"
for s in design plan; do "$P/scripts/next.sh" "$a1" >/dev/null 2>&1; ra="$(record get "$a1" run.reports)"; printf '{"status":"done","summary":"planned"}\n' > "$ra/$s.json"; "$P/scripts/advance.sh" "$a1" >/dev/null 2>&1; code=$?; done
check_all "plan-approval is auto-approved for a listed size" '[ "$code" -eq 0 ] && [ "$(record get "$a1" step)" = "implement" ] && [ "$(record get "$a1" gate)" != "plan-approval" ] && grep -q '\''auto-approved (size M)'\'' .flow/events.log'
a2="$("$P/scripts/new.sh" task "Big plan" --size L --body "## Acceptance
- [ ] x")"
for s in design plan; do "$P/scripts/next.sh" "$a2" >/dev/null 2>&1; rb2="$(record get "$a2" run.reports)"; printf '{"status":"done"}\n' > "$rb2/$s.json"; "$P/scripts/advance.sh" "$a2" >/dev/null 2>&1; code=$?; done
check_all "an unlisted size still stops at plan-approval" '[ "$code" -eq 4 ] && [ "$(record get "$a2" gate)" = "plan-approval" ]'
printf 'adapters:\n  default: local\nbase: main\npool_max: 1\nauto_gates:\n  merge: S\n' > .flow/config.yaml
check "init: --check flags an auto gate that is not allowed" sh -c "FLOW_PLUGIN='$P' '$P/skills/init/scripts/init.sh' --check | grep -q 'gap: .flow/config.yaml: auto_gates lists merge'"
branch_check() { printf 'adapters:\n  default: local\nbase: main\npool_max: 1\n%s\n' "$1" > .flow/config.yaml; FLOW_PLUGIN="$P" "$P/skills/init/scripts/init.sh" --check > "$work/branch-check.out" 2>&1; }
branch_check 'branch: task/{ticket}'; code=$?
check "InitCheckOfAnUnknownPlaceholder_NamesItAsABranchGap: a template with {ticket} would claim a branch named with the brace text, so init names it" grep -q 'gap: .flow/config.yaml: branch.*{ticket}' "$work/branch-check.out"
check "InitCheckOfAnUnknownPlaceholder_ExitsDrift: a bad template is drift, so a scripted init check fails" [ "$code" -eq 1 ]
branch_check 'branch:
  story: story/{key}'
check "InitCheckOfAnUnknownKindKey_NamesTheKind: branch takes only epic, task and bug, so a story template is never read" grep -q 'gap: .flow/config.yaml: branch.story' "$work/branch-check.out"
branch_check 'branch: task/{title}'
check "InitCheckOfATemplateWithNeitherKeyNorSlug_IsABranchGap: two items with one title would share a branch" grep -q 'gap: .flow/config.yaml: branch.*task/{title}' "$work/branch-check.out"
branch_check 'branch:
  task: task/{key}-{title}
  bug: bugfix/{key}-{title}
  epic: feature/{key}-{title}'
check_all "InitCheckOfAValidPerKindMap_ReportsNoBranchGap: the item's own CI-prefix example is a valid config" '[ -s "$work/branch-check.out" ] && ! grep -q "gap: .flow/config.yaml: branch" "$work/branch-check.out"'
echo "a full pool: next skips what needs a new worktree"
mkdir -p "$work/full" && cd "$work/full" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 1\nnotify:\n  desktop: false\n' > .flow/config.yaml
f1="$("$P/scripts/new.sh" task "Needs a worktree" --size S --body "## Acceptance
- [ ] a")"
f2="$("$P/scripts/new.sh" task "Holds a worktree" --size S --body "## Acceptance
- [ ] b")"
"$P/scripts/steward.sh" claim "$f2" >/dev/null 2>&1
out="$("$P/scripts/next.sh" --json 2>/dev/null)"; code=$?
check "a full pool: next takes the item that holds a claim, not exit 3" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$f2"
"$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check "a full pool with only unclaimed items left: exit 3, not 5" [ "$code" -eq 3 ]
check "the pick lock is released after a skipped pick" [ ! -d .flow/pick.lock ]
check "a skipped pick leaves no cached ready list behind" sh -c '! ls .flow/tmp/.ready.* >/dev/null 2>&1'
end_run "$f2"
out="$(FLOW_NEXT_SKIP="$f2" "$P/scripts/next.sh" --json 2>/dev/null)"; code=$?
check "a FLOW_NEXT_SKIP from the caller's environment is ignored" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$f2"
"$P/scripts/next.sh" "$f1" >/dev/null 2>&1; code=$?
check "a named item that needs a worktree still exits 3" [ "$code" -eq 3 ]

echo "a pick passes over an item with nothing to run"
mkdir -p "$work/pass" && cd "$work/pass" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 2\nnotify:\n  desktop: false\n' > .flow/config.yaml
pa="$("$P/scripts/new.sh" task "Every step ran" --size S --priority P0 --body "## Acceptance
- [ ] a")"
pb="$("$P/scripts/new.sh" task "Fresh" --size S --priority P1 --body "## Acceptance
- [ ] b")"
stale="$("$P/adapters/local/list-ready.sh")"
record set "$pa" step=done
check "ready: an open item whose every step ran is not ready" sh -c "! '$P/adapters/local/list-ready.sh' | grep -q '\"$pa\"'"
out="$("$P/scripts/next.sh" --json 2>"$work/pass.err")"; code=$?
check "a pick leaves the item whose every step ran to the owner and takes the next" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$pb"
end_run "$pb"
# The ready list a pick reads can be older than the item's state: here a gate raised in between.
record set "$pa" step=implement gate=plan-approval
out="$(stale_pick "$stale" 2>"$work/pass.err")"; code=$?
check "a pick passes over an item its ready list holds that waits at a gate, and says so" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ] && grep -q "$4 waits at gate .plan-approval." "$5"' _ "$code" "$(printf '%s' "$out" | jget item)" "$pb" "$pa" "$work/pass.err"
stale_pick "$stale" >/dev/null 2>"$work/pass.err"; code=$?
check "a pass-over with nothing left is nothing ready (exit 5), not a full pool (exit 3)" sh -c "[ $code -eq 5 ] && grep -q 'nothing ready' '$work/pass.err'"
check "a pass-over leaves no cached ready list behind" sh -c '! ls .flow/tmp/.ready.* >/dev/null 2>&1'
"$P/scripts/next.sh" "$pa" >/dev/null 2>&1; code=$?
check "a named item at a gate still exits 4" [ "$code" -eq 4 ]
record set "$pa" step=done gate=none
"$P/scripts/next.sh" "$pa" >/dev/null 2>&1; code=$?
check "a named item whose every step ran still exits 6" [ "$code" -eq 6 ]
end_run "$pb"
out="$(stale_pick "$stale" 2>"$work/pass.err")"; code=$?
check "a pick passes over an item its ready list holds whose every step ran, and says so" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ] && grep -q "$4 is done (every step ran)" "$5"' _ "$code" "$(printf '%s' "$out" | jget item)" "$pb" "$pa" "$work/pass.err"
# The pool is full (pb holds its one worktree) and pc needs one: a pass-over and a full-pool skip
# in one pick end in exit 3, as the pool is what stops the work.
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../app-wt-1\npool_max: 1\nnotify:\n  desktop: false\n' > .flow/config.yaml
pc="$("$P/scripts/new.sh" task "Needs a worktree" --size S --priority P2 --body "## Acceptance
- [ ] c")"
record set "$pa" step=implement
stale="$("$P/adapters/local/list-ready.sh")"
record set "$pa" step=done
stale_pick "$stale" >/dev/null 2>"$work/pass.err"; code=$?
check "a pass-over and a full-pool skip in one pick: exit 3, the pool is what stops the work" sh -c "[ $code -eq 3 ] && grep -q '$pa is done' '$work/pass.err' && grep -q 'no free worktree' '$work/pass.err'"
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$work/pass.out" 2>&1
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$work/pass.out2" 2>&1
check "health: an open item whose every step ran is said once: merge or close it" sh -c "grep -q '$pa: done (every step ran) and still open: merge or close it' '$work/pass.out' && grep -q '; 1 finding(s)' '$work/pass.out' && ! grep -q 'merge or close it' '$work/pass.out2'"
record set "$pa" step=implement
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health >/dev/null 2>&1
record set "$pa" step=done
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$work/pass.out3" 2>&1
check "health: an item sent back to a step and done again is said again" grep -q "$pa: done (every step ran) and still open" "$work/pass.out3"
check "next job: a named item whose every step ran says so, not done" sh -c "'$P/jobs/next.sh' claude '$pa' | grep -q '$pa is done (every step ran). Merge or close it.'"
check "next job: a pick that ran no step says so, with the reason, instead of done" sh -c "'$P/jobs/next.sh' claude --max-steps 0 | grep -q 'stopped: no step ran (exit 0: run-unattended: step budget 0 reached)'"
# A host stub that does the step: it writes the report the brief names, with no newline after
# its own last line, so the step line that follows is glued to it in the log.
mkdir -p "$work/dobin"
cat > "$work/dobin/claude" <<'STUB'
#!/bin/sh
brief="$(printf '%s' "$*" | sed -n 's/.*Follow the brief in \([^ ]*\) .*/\1/p')"
report="$(sed -n 's/^Write `\(.*\)`:$/\1/p' "$brief" | head -1)"
mkdir -p "$(dirname "$report")" && printf '{"status":"done","summary":"stub"}\n' > "$report"
printf 'did the step'
STUB
chmod +x "$work/dobin/claude"
end_run "$pb"
check "next job: the last word counts the steps the run made, even after host output with no newline" sh -c "PATH='$work/dobin:$PATH' '$P/jobs/next.sh' claude --max-steps 1 | grep -q 'done, 1 step'"
check "jobs: a run that stopped without a step counts as failed in the week, not as work" sh -c "'$P/scripts/jobs.sh' status | grep '^| next ' | grep -q '1 failed'"

echo "holds: an item a plan put behind another waits while that one is open"
mkdir -p "$work/hold" && cd "$work/hold" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 3\nnotify:\n  desktop: false\n' > .flow/config.yaml
# The held item is listed first, so a pick meets it before its holder.
hb="$("$P/scripts/new.sh" task "Held" --size S --body "## Acceptance
- [ ] b")"
ha="$("$P/scripts/new.sh" task "Holder" --size S --body "## Acceptance
- [ ] a")"
stale="$("$P/adapters/local/list-ready.sh")"
record set "$hb" "held_by=$ha" "held_reason=changes src/a.c, which $ha rewrites"
check "ready: an item held behind an open item is not ready" sh -c "! '$P/adapters/local/list-ready.sh' | grep -q '\"$hb\"'"
"$P/scripts/next.sh" "$hb" >/dev/null 2>"$work/hold.err"; code=$?
check "a named held item exits 4 and says who it waits behind and why" sh -c "[ $code -eq 4 ] && grep -qx '$hb is held behind $ha: changes src/a.c, which $ha rewrites' '$work/hold.err'"
out="$("$P/scripts/next.sh" --json 2>/dev/null)"; code=$?
check "a pick leaves the held item, though it is listed first, and takes its holder" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$ha"
"$P/scripts/next.sh" >/dev/null 2>"$work/hold.err"; code=$?
check "nothing ready names the held item and its holder" sh -c "[ $code -eq 5 ] && grep -qx 'nothing ready: 1 running, 1 held ($hb behind $ha)' '$work/hold.err'"
stale_pick "$stale" >/dev/null 2>"$work/hold.err"; code=$?
check "a pick whose ready list is older than the hold passes the held item over, and says so" sh -c "[ $code -eq 5 ] && grep -q '^$hb is held behind $ha: ' '$work/hold.err' && tail -n 1 '$work/hold.err' | grep -qx 'nothing ready: 1 running, 1 passed over (said above)'"
check "next job: a named held item is a quiet run that says who it waits behind" sh -c "'$P/jobs/next.sh' claude '$hb' | grep -q 'quiet: $hb is held behind $ha: changes src/a.c'"
"$P/adapters/local/close.sh" "$ha" --comment done
end_run "$ha"; "$P/scripts/steward.sh" release "$ha" --force >/dev/null 2>&1
out="$("$P/scripts/next.sh" --json 2>/dev/null)"; code=$?
check "once its holder is closed the held item is picked" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$hb"
hc="$("$P/scripts/new.sh" task "Held behind nothing" --size S --body "## Acceptance
- [ ] c")"
record set "$hc" held_by=local:task/999 "held_reason=gone"
check "ready: a holder that cannot be found holds nothing" sh -c "'$P/adapters/local/list-ready.sh' | grep -q '\"$hc\"'"

echo "a full pool: one pass with no tracker read per unclaimed item"
mkdir -p "$work/fullpass" && cd "$work/fullpass" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 3\nnotify:\n  desktop: false\n' > .flow/config.yaml
# The unclaimed items are listed first, so a pick meets them before the claimed ones.
for t in one two three; do "$P/scripts/new.sh" task "Unclaimed $t" --size S --body "## Acceptance
- [ ] $t" >/dev/null; done
u1=local:task/1
for t in one two three; do "$P/scripts/new.sh" task "Claimed $t" --size S --body "## Acceptance
- [ ] $t" >/dev/null; done
c1=local:task/4; c2=local:task/5; c3=local:task/6
"$P/scripts/next.sh" "$c1" >/dev/null 2>&1
"$P/scripts/steward.sh" claim "$c2" >/dev/null 2>&1; "$P/scripts/steward.sh" claim "$c3" >/dev/null 2>&1
record set "$c2" "held_by=$c1" "held_reason=both rewrite src/a.c"
# A plugin copy whose local read notes each item it reads: the tracker calls a pick makes.
counting="$work/plugin-counting"; cp -R "$P" "$counting"; rm -rf "$counting/evals/results"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/reads.log"\nexec "%s/adapters/local/read.sh" "$@"\n' "$work" "$P" > "$counting/adapters/local/read.sh"
: > "$work/reads.log"
out="$(FLOW_PLUGIN="$counting" "$counting/scripts/next.sh" --json 2>/dev/null)"; code=$?
check "a full pool: after the one claim that found it full, the pick takes the claimed item listed last" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$c3"
check "a full pool: the unclaimed items after the first are passed with no tracker read" sh -c "[ \"\$(cat '$work/reads.log' | tr '\n' ' ')\" = '$u1 $c3 ' ]"
: > "$work/reads.log"
FLOW_PLUGIN="$counting" "$counting/scripts/next.sh" >/dev/null 2>"$work/fullpass.err"; code=$?
check "a full pool with nothing claimed to run: one read, then exit 3" sh -c "[ $code -eq 3 ] && [ \"\$(cat '$work/reads.log' | tr '\n' ' ')\" = '$u1 ' ]"
check "a full pool says why: the unclaimed items waiting, and what the claimed ones are doing" sh -c "tail -n 1 '$work/fullpass.err' | grep -qx 'no free worktree for the 3 unclaimed ready item(s), and the pool is at pool_max; the claimed items: 2 running, 1 held ($c2 behind $c1)'"
check "the pick lock is released after a full-pool pass" [ ! -d .flow/pick.lock ]
check "next job: a full pool is a quiet run that carries the reason" sh -c "'$P/jobs/next.sh' claude --max-steps 1 | grep -q 'quiet: no free worktree for the 3 unclaimed ready item(s), .* 1 held ($c2 behind $c1)\$'"
check "health still reads a full pool from the next job's last word" sh -c "python3 '$P/scripts/_health.py' last-next .flow/log | grep -q 'no free worktree'"

echo "parallel runs: the pick lock and --workers"
mkdir -p "$work/par" && cd "$work/par" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 3\nnotify:\n  desktop: false\n' > .flow/config.yaml
for t in one two; do "$P/scripts/new.sh" task "Parallel $t" --size S --body "## Acceptance
- [ ] $t" >/dev/null; done
"$P/scripts/next.sh" --json > "$work/p1.json" 2>/dev/null & q1=$!
"$P/scripts/next.sh" --json > "$work/p2.json" 2>/dev/null & q2=$!
wait "$q1"; wait "$q2"
i1="$(jget item < "$work/p1.json")"; i2="$(jget item < "$work/p2.json")"
w1="$(jget worktree < "$work/p1.json")"; w2="$(jget worktree < "$work/p2.json")"
check_all "two runs started together take two items" '[ -n "$i1" ] && [ -n "$i2" ] && [ "$i1" != "$i2" ]'
check_all "...in two worktrees" '[ -n "$w1" ] && [ "$w1" != "$w2" ]'
check "the pick lock is released after the pick" [ ! -d .flow/pick.lock ]
sleep 30 & held=$!
mkdir -p .flow/pick.lock && echo "$held" > .flow/pick.lock/pid
"$P/scripts/new.sh" task "Parallel three" --size S --body "## Acceptance
- [ ] three" >/dev/null
FLOW_LOCK_WAIT=1 "$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check "a live holder makes the next pick wait, then exit 7 (quiet)" [ "$code" -eq 7 ]
lying_mkdir="$work/lying-mkdir"; mkdir -p "$lying_mkdir"
printf '#!/bin/sh\nexec %s -p "$@"\n' "$(command -v mkdir)" > "$lying_mkdir/mkdir" && chmod +x "$lying_mkdir/mkdir"
PATH="$lying_mkdir:$PATH" FLOW_LOCK_WAIT=1 "$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check "MkdirThatExitsZeroOnExistingDirectory_PickWaitsForLiveHolder: the pick exits 7 (quiet) because only the call that makes the lock directory holds the lock" [ "$code" -eq 7 ]
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null
FLOW_LOCK_WAIT=1 "$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check_all "a stale lock (holder gone) is taken over" '[ "$code" -eq 0 ] && [ ! -d .flow/pick.lock ]'
for running_item in $(running_items); do "$P/scripts/steward.sh" release "$running_item" --force >/dev/null 2>&1; end_run "$running_item"; done
# A plugin copy whose local list-ready ends the lock holder before it lists: a pick that lists
# before it locks then finds the lock stale and takes it; one that locks first waits and gives up.
slow="$work/plugin-slow"; cp -R "$P" "$slow"; rm -rf "$slow/evals/results"
printf '#!/bin/sh\nkill "$(cat .flow/pick.lock/pid)" 2>/dev/null; sleep 2; exec "%s/adapters/local/list-ready.sh" "$@"\n' "$P" > "$slow/adapters/local/list-ready.sh"
"$P/scripts/new.sh" task "Parallel four" --size S --body "## Acceptance
- [ ] four" >/dev/null
sleep 30 & held=$!
mkdir -p .flow/pick.lock && echo "$held" > .flow/pick.lock/pid
FLOW_PLUGIN="$slow" FLOW_LOCK_WAIT=1 "$slow/scripts/next.sh" >/dev/null 2>&1; code=$?
check "the ready list is read before the pick lock, so a slow listing never counts against the lock wait" [ "$code" -eq 0 ]
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null
for running_item in $(running_items); do "$P/scripts/steward.sh" release "$running_item" --force >/dev/null 2>&1; end_run "$running_item"; done
: > "$HOST_LOG"
# The slow host notes its process group, then holds until the test says go.
mkdir -p "$work/slow"; rm -f "$work/slow.go" "$work/slow.groups"
printf '#!/bin/sh\npython3 -I -c "import os; print(os.getpgrp())" >> "%s/slow.groups"\nn=0; while [ ! -f "%s/slow.go" ] && [ "$n" -lt 60 ]; do sleep 1; n=$((n + 1)); done\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' "$work" "$work" > "$work/slow/claude"; chmod +x "$work/slow/claude"
PATH="$work/slow:$PATH" "$P/jobs/next.sh" claude --workers 2 --max-steps 1 >/dev/null 2>&1; code=$?
check_all "--workers: the job starts the workers and ends before they do" '[ "$code" -eq 0 ] && [ ! -s "$HOST_LOG" ]'
both_sessions_started() { [ "$(grep -c . "$work/slow.groups" 2>/dev/null)" = 2 ]; }
waited=0; while ! both_sessions_started && [ "$waited" -lt 60 ]; do sleep 1; waited=$((waited + 1)); done
touch "$work/slow.go"
waited=0; while { [ "$(grep -c . "$HOST_LOG")" -lt 2 ] || ls -d .flow/log/next-[0-9]*.lock; } >/dev/null 2>&1 && [ "$waited" -lt 60 ]; do sleep 1; waited=$((waited + 1)); done
check "--workers: the workers end within a minute" [ "$waited" -lt 60 ]
[ "$waited" -lt 60 ] || for d in .flow/log/next-[0-9]*.lock; do kill "$(cat "$d/pid")" 2>/dev/null; rm -rf "$d"; done
own_group="$(python3 -I -c 'import os; print(os.getpgrp())')"
check_all "--workers: each worker runs outside the job's process group, so the scheduler ending the job spares them" '[ "$(grep -c . "$work/slow.groups")" = 2 ] && ! tr -d " " < "$work/slow.groups" | grep -qx "$own_group"'
check_all "--workers 2: two loops, two logs" '[ -f .flow/log/next-1.log ] && [ -f .flow/log/next-2.log ]'
sleep 30 & held=$!
mkdir -p .flow/pick.lock && echo "$held" > .flow/pick.lock/pid
check "next job: a worker that waited out the pick lock says so, not that a run is in flight" sh -c "FLOW_LOCK_WAIT=1 '$P/jobs/next.sh' claude --max-steps 1 | grep -q 'quiet: another worker held the pick for over 1s'"
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null; rm -rf .flow/pick.lock
check "--workers 2: each worker ran a step in its own worktree" [ "$(cut -f2 "$HOST_LOG" | sort -u | grep -c .)" = 2 ]
log_lines_1="$(grep -c . .flow/log/next-1.log)"; log_lines_2="$(grep -c . .flow/log/next-2.log)"
"$P/jobs/next.sh" claude --workers 2 --max-steps 1 --wait >/dev/null 2>&1
check_all "--workers --wait: the job ends after every worker" '[ "$(grep -c . .flow/log/next-1.log)" -gt "$log_lines_1" ] && [ "$(grep -c . .flow/log/next-2.log)" -gt "$log_lines_2" ] && ! ls -d .flow/log/next-[0-9]*.lock'
failing="$work/plugin-failing"; cp -R "$P" "$failing"; rm -rf "$failing/evals/results"
printf '#!/bin/sh\nexit 9\n' > "$failing/templates/run-unattended.sh"
FLOW_PLUGIN="$failing" "$failing/jobs/next.sh" claude --workers 2 --max-steps 1 --wait >/dev/null 2>&1; code=$?
check "--workers --wait: a worker's failure is the job's exit" [ "$code" -eq 9 ]
check "--workers with an item is refused" sh -c "! '$P/jobs/next.sh' claude local:task/1 --workers 2 2>/dev/null"
check "--workers 0 is refused" sh -c "! '$P/jobs/next.sh' claude --workers 0 2>/dev/null"
# A plugin copy whose loop only notes the host it was given: which worker ran where.
hosted="$work/plugin-hosted"; cp -R "$P" "$hosted"; rm -rf "$hosted/evals/results"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s/hosted.log"\nprintf "%%s\\n" "$*" >> "%s/hosted.args"\n' "$work" "$work" > "$hosted/templates/run-unattended.sh"
cp .flow/config.yaml "$work/config.par"; printf 'jobs:\n  workers: {claude: 1, codex: 2}\n' >> .flow/config.yaml
runs_before="$(wc -l < .flow/log/runs.jsonl | tr -d ' ')"
: > "$work/hosted.log"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" claude --max-steps 1 --wait >/dev/null 2>&1; code=$?
check "jobs.workers: one next run starts each worker on its host" sh -c "[ $code = 0 ] && [ \"\$(sort '$work/hosted.log' | tr '\\n' ' ')\" = 'claude codex codex ' ]"
# Only this run's lines, each whole: three workers end at once, and each line is one write.
check "jobs.workers: next-1 ran on claude, next-2 and next-3 on codex, as runs.jsonl says" sh -c "python3 -c 'import json,sys; new=[json.loads(l) for l in open(sys.argv[1]).readlines()[int(sys.argv[2]):]]; got={(r[\"job\"],r.get(\"host\")) for r in new}; assert {(\"next-1\",\"claude\"),(\"next-2\",\"codex\"),(\"next-3\",\"codex\")} <= got, new' .flow/log/runs.jsonl $runs_before"
: > "$work/hosted.log"; : > "$work/hosted.args"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" claude --max-steps 1 --model claude-once-z --effort high --wait >/dev/null 2>&1
check "jobs.workers: --model and --effort reach the workers on the host named; the others keep their pair" sh -c "grep -qx 'claude --max-steps 1 --model claude-once-z --effort high' '$work/hosted.args' && [ \"\$(grep -cx 'codex --max-steps 1' '$work/hosted.args')\" = 2 ]"
: > "$work/hosted.log"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" codex --workers 2 --max-steps 1 --wait >/dev/null 2>&1
check "jobs.workers: --workers N on the command line starts N on the host it names instead" [ "$(sort "$work/hosted.log" | tr '\n' ' ')" = 'codex codex ' ]
runs_before="$(wc -l < .flow/log/runs.jsonl | tr -d ' ')"
: > "$work/hosted.log"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" codex --as next-codex --workers 2 --max-steps 1 --wait >/dev/null 2>&1; code=$?
check "a named next schedule's workers lock, log and record as <name>-<n>" sh -c "[ $code = 0 ] && [ \"\$(sort '$work/hosted.log' | tr '\\n' ' ')\" = 'codex codex ' ] && [ -f .flow/log/next-codex-1.log ] && [ -f .flow/log/next-codex-2.log ] && python3 -c 'import json,sys; new=[json.loads(l) for l in open(sys.argv[1]).readlines()[int(sys.argv[2]):]]; got={(r[\"job\"],r.get(\"host\")) for r in new}; assert got=={(\"next-codex-1\",\"codex\"),(\"next-codex-2\",\"codex\")}, new' .flow/log/runs.jsonl $runs_before"
: > "$work/hosted.log"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" codex --as next-gh81 --max-steps 1 >/dev/null 2>&1
check "a named next schedule leaves jobs.workers to the plain next: with no --workers it is one run" sh -c "[ \"\$(cat '$work/hosted.log')\" = codex ] && tail -1 .flow/log/runs.jsonl | grep -q '\"job\":\"next-gh81\",\"host\":\"codex\"'"
FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" codex --as next-1 > "$work/hosted.out" 2>&1; code=$?
check "--as refuses a name that is no schedule of the job" sh -c "[ $code = 2 ] && grep -q -- '--as next-1 is no schedule of next' '$work/hosted.out'"
printf '#!/bin/sh\nsleep 60 &\nwait\n' > "$work/fake/jobs/next.sh"; chmod +x "$work/fake/jobs/next.sh"
fakenext="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/next.sh")"
mkdir -p .flow/log/next.lock && echo "$fakenext" > .flow/log/next.lock/pid
: > "$work/hosted.log"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" claude local:task/1 --as next-codex --max-steps 1 >/dev/null 2>&1
check "two next schedules hold separate locks: a live next does not skip next-codex" sh -c "[ \"\$(cat '$work/hosted.log')\" = claude ] && tail -1 .flow/log/runs.jsonl | grep -q '\"job\":\"next-codex\",\"host\":\"claude\".*\"result\":\"done'"
: > "$work/hosted.log"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" claude local:task/1 --max-steps 1 >/dev/null 2>&1
check "two next schedules hold separate locks: a second run of next itself is still skipped" sh -c "[ ! -s '$work/hosted.log' ] && tail -1 .flow/log/runs.jsonl | grep -q '\"job\":\"next\".*\"result\":\"skipped: run $fakenext still going'"
pkill -P "$fakenext" 2>/dev/null; kill "$fakenext" 2>/dev/null; rm -rf .flow/log/next.lock
: > "$work/hosted.log"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" claude local:task/1 --max-steps 1 >/dev/null 2>&1
check "jobs.workers: a run for one item is one run on the host it names" [ "$(cat "$work/hosted.log")" = claude ]
cp "$work/config.par" .flow/config.yaml; printf 'jobs:\n  workers: {claude: 1, gemini: 1}\n' >> .flow/config.yaml
: > "$work/hosted.log"; FLOW_PLUGIN="$hosted" "$hosted/jobs/next.sh" claude --max-steps 1 --wait > "$work/hosted.out" 2>&1; code=$?
check "jobs.workers: a host other than claude or codex stops the run, exit 2, before any worker" sh -c "[ $code = 2 ] && [ ! -s '$work/hosted.log' ] && grep -q \"jobs.workers names the host 'gemini'\" '$work/hosted.out'"
check "jobs.workers: the refused run is a failed run in runs.jsonl, so status shows it" sh -c "tail -1 .flow/log/runs.jsonl | grep -q '\"job\":\"next\".*\"exit\":2,\"result\":\"error: .*jobs.workers names the host'"
cp "$work/config.par" .flow/config.yaml
cd "$repo"

echo "pick filters: next --pick"
mkdir -p "$work/pick" && cd "$work/pick" && git init -q -b main app && cd app && git config user.email me@pick.test && git config user.name t
printf 'hi\n' > README.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init && mkdir -p .flow
pick_config() { # pick_config <the pick block's lines>: local items, P0 first, any assignee, and the filters given
  printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 2\nready:\n  priority_order: [P0, P1, P2]\n  assignee: any\nnotify:\n  desktop: false\npick:\n%s\n' "$1" > .flow/config.yaml
}
assign_local() { # assign_local <id> <who>: the item file's assignee
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(t.replace("---\n", "---\nassignee: %s\n" % sys.argv[2], 1))' ".flow/items/$(printf '%s' "${1#local:}").md" "$2"
}
unpick() { # unpick <next.sh --json output>: the run and its claim go, so the next pick starts clean
  end_run "$(printf '%s' "$1" | jget item)"
  "$P/scripts/steward.sh" release "$(printf '%s' "$1" | jget item)" --force >/dev/null 2>&1
}
pick_config '  mine:
    assignee: me
  urgent:
    labels: [urgent]
    kinds: [bug]'
kt="$("$P/adapters/local/create.sh" task "Theirs, most urgent" --size S --priority P0)"
km2="$("$P/adapters/local/create.sh" task "Mine, least urgent" --size S --priority P2)"
km1="$("$P/adapters/local/create.sh" task "Mine, urgent" --size S --priority P1)"
kmb="$("$P/adapters/local/create.sh" task "Mine, most urgent but blocked" --size S --priority P0 --blocked-by "$kt")"
assign_local "$kt" other@pick.test; assign_local "$km2" me@pick.test; assign_local "$km1" me@pick.test; assign_local "$kmb" me@pick.test
out="$("$P/scripts/next.sh" --json --pick mine 2>/dev/null)"
check "next --pick: takes the most urgent ready item the filter keeps; the blocker and the order apply after it" [ "$(printf '%s' "$out" | jget item)" = "$km1" ]
unpick "$out"
out="$("$P/scripts/next.sh" --json 2>/dev/null)"
check "next with no filter still takes the most urgent ready item of all" [ "$(printf '%s' "$out" | jget item)" = "$kt" ]
unpick "$out"
record set "$km1" gate=plan-approval
out="$("$P/scripts/next.sh" --json --pick mine 2>/dev/null)"
check "next --pick: an item the filter keeps that waits at a gate is passed over" [ "$(printf '%s' "$out" | jget item)" = "$km2" ]
unpick "$out"
"$P/scripts/next.sh" --pick urgent >/dev/null 2>"$work/pick.err"; code=$?
check "next --pick: a filter that keeps no ready item is nothing ready (exit 5)" sh -c "[ $code -eq 5 ] && grep -q 'nothing ready' '$work/pick.err'"
"$P/scripts/next.sh" --pick theirs >/dev/null 2>"$work/pick.err"; code=$?
check "next --pick: an unknown filter is refused (exit 2) with the filters the config names" sh -c "[ $code -eq 2 ] && grep -q 'pick has no filter theirs in .flow/config.yaml; the filters are mine urgent' '$work/pick.err'"
"$P/scripts/next.sh" "$km2" --pick mine >/dev/null 2>"$work/pick.err"; code=$?
check "next --pick: a named item beside a filter is refused (exit 2)" sh -c "[ $code -eq 2 ] && grep -q -- '--pick narrows the ready list' '$work/pick.err'"
pick_config '  raw:
    query: assignee = currentUser()'
"$P/scripts/next.sh" --pick raw >/dev/null 2>"$work/pick.err"; code=$?
check "pick: a query with no tracker is refused (exit 2): it goes to exactly one" sh -c "[ $code -eq 2 ] && grep -q 'set pick.raw.trackers to exactly one tracker, not none' '$work/pick.err'"
pick_config '  raw:
    query: label:api
    trackers: [github]
    assignee: me'
"$P/scripts/next.sh" --pick raw >/dev/null 2>"$work/pick.err"; code=$?
check "pick: a query beside a neutral field is refused (exit 2)" sh -c "[ $code -eq 2 ] && grep -q 'pick.raw.query goes to github as written, so the filter takes no assignee' '$work/pick.err'"
pick_config '  raw:
    query: label:api
    trackers: [github]
    assignee: ""
    labels: []
    status:'
"$P/scripts/next.sh" --pick raw >/dev/null 2>"$work/pick.err"; code=$?
check "pick: neutral fields Settings cleared beside a query are unset, so the filter passes to its tracker" sh -c "! grep -q 'so the filter takes no' '$work/pick.err' && grep -q 'pick.raw.trackers names github, which the flow does not read' '$work/pick.err'"
pick_config '  mine:
    assignee: me
    labels: []
    query: ""'
out="$("$P/scripts/next.sh" --json --pick mine 2>"$work/pick.err")"
check "pick: a cleared field the adapter cannot map is unset, so the filter still picks" [ "$(printf '%s' "$out" | jget item)" = "$km2" ]
unpick "$out"
pick_config '  raw:
    query: status = Open
    trackers: [local]'
"$P/scripts/next.sh" --pick raw >/dev/null 2>"$work/pick.err"; code=$?
check "pick: a field the adapter cannot map is refused (exit 2) with the fields it maps" sh -c "[ $code -eq 2 ] && grep -q 'pick.raw.query: the local adapter maps assignee, status, labels and kinds, not query' '$work/pick.err'"
pick_config '  mine:
    assignee: me
    trackers: [github]'
"$P/scripts/next.sh" --pick mine >/dev/null 2>"$work/pick.err"; code=$?
check "pick: a tracker the flow does not read is refused (exit 2) with the ones it reads" sh -c "[ $code -eq 2 ] && grep -q 'pick.mine.trackers names github, which the flow does not read; it reads local' '$work/pick.err'"
pick_config '  mine:
    assignee: me'
picks="$work/plugin-picks"; cp -R "$P" "$picks"; rm -rf "$picks/evals/results"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/picks.args"\n' "$work" > "$picks/templates/run-unattended.sh"
: > "$work/picks.args"; FLOW_PLUGIN="$picks" "$picks/jobs/next.sh" claude --pick mine --max-steps 1 >/dev/null 2>&1
check "next job: --pick reaches the unattended loop" grep -qx 'claude --pick mine --max-steps 1' "$work/picks.args"
: > "$work/picks.args"; FLOW_PLUGIN="$picks" "$picks/jobs/next.sh" claude --pick theirs --max-steps 1 > "$work/pick.err" 2>&1; code=$?
check "next job: an unknown filter stops the run (exit 2) before the loop starts" sh -c "[ $code -eq 2 ] && [ ! -s '$work/picks.args' ] && grep -q 'pick has no filter theirs' '$work/pick.err'"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/picks.next"\nexit 5\n' "$work" > "$picks/scripts/next.sh"
cp "$P/templates/run-unattended.sh" "$picks/templates/run-unattended.sh"; : > "$work/picks.next"
FLOW_PLUGIN="$picks" "$picks/templates/run-unattended.sh" claude --pick mine --max-steps 1 >/dev/null 2>&1
check "unattended loop: picks its item through next.sh --pick" grep -qx -- '--json --embed-agent --pick mine' "$work/picks.next"
cd "$repo"

echo "tracker scope: every read of the local tracker"
mkdir -p "$work/scope/bin" && cd "$work/scope" && git init -q -b main app && cd app && git config user.email me@scope.test && git config user.name t
printf 'hi\n' > README.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init && mkdir -p .flow
scope_config() { # scope_config <the local.scope block's lines> [<top-level lines after it>]: local items, a pool that grows
  printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 3\nready:\n  priority_order: [P0, P1, P2]\nnotify:\n  desktop: false\ngithub:\n  repo: acme/widgets\nlocal:\n  scope:\n%s\n%s' "$1" "${2:-}" > .flow/config.yaml
}
scope_ids() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(i["id"] for i in (d["items"] if isinstance(d, dict) else d)))'; }
scope_unpick() { # scope_unpick <next.sh --json output>: the run and its claim go, so the next pick starts clean
  end_run "$(printf '%s' "$1" | jget item)"
  "$P/scripts/steward.sh" release "$(printf '%s' "$1" | jget item)" --force >/dev/null 2>&1
}
scope_config '    labels: [team-a]'
sin="$("$P/adapters/local/create.sh" task "Inside the scope" --size S --priority P1 --labels team-a)"
sout="$("$P/adapters/local/create.sh" task "Outside the scope, more urgent" --size S --priority P0 --labels team-b)"
board_ids="$("$P/scripts/board.sh" --json 2>/dev/null | scope_ids)"
check_all "ScopedBoard_ShowsItemInside: board --json lists an item local.scope matches, because the scope only narrows" 'case " $board_ids " in *" $sin "*) true ;; *) false ;; esac'
check_all "ScopedBoard_HidesItemOutside: board --json leaves out an item outside local.scope, because it reads the scoped list" '[ -n "$board_ids" ] && case " $board_ids " in *" $sout "*) false ;; *) true ;; esac'
out="$("$P/scripts/next.sh" --json 2>/dev/null)"
check "ScopedNext_PicksOnlyInside: next takes the item inside the scope over a more urgent one outside it, because it picks from the scoped list" [ "$(printf '%s' "$out" | jget item)" = "$sin" ]
scope_unpick "$out"
scope_config '    labels: [team-a]' 'pick:
  tasks:
    kinds: [task]
'
out="$("$P/scripts/next.sh" --json --pick tasks 2>/dev/null)"
check "ScopedNextPick_PicksOnlyInside: next --pick takes the item inside the scope, because the scope and the pick both apply" [ "$(printf '%s' "$out" | jget item)" = "$sin" ]
scope_unpick "$out"
scope_config '    labels: [team-a]'
"$P/scripts/next.sh" "$sout" >/dev/null 2>"$work/scope.err"; code=$?
check "NextNamedOutsideScope_ExitsTwo: next on a named item outside the scope is refused, because the flow runs no item outside its scope" [ "$code" -eq 2 ]
check "NextNamedOutsideScope_NamesScope: the refusal names local.scope, because that is the key to change" grep -q "$sout is outside local.scope in .flow/config.yaml" "$work/scope.err"
"$P/scripts/steward.sh" claim "$sout" >/dev/null 2>"$work/scope.err"; code=$?
check "ClaimOutsideScope_ExitsTwo: a new claim of an item outside the scope is refused, because the flow runs no item outside its scope" [ "$code" -eq 2 ]
check "ClaimOutsideScope_TakesNoWorktree: the refused claim leaves no worktree claimed for the item, because a refusal changes nothing" [ -z "$("$P/scripts/steward.sh" find "$sout")" ]
adhoc_path="$("$P/scripts/steward.sh" claim adhoc:scope-x 2>/dev/null)"
check "ClaimAdhoc_IsNeverScoped: an adhoc: claim has no tracker, so a scope does not refuse it, because a scope belongs to its tracker" [ -n "$adhoc_path" ]
"$P/scripts/steward.sh" release adhoc:scope-x --force >/dev/null 2>&1
held_path="$("$P/scripts/steward.sh" claim "$sin" 2>/dev/null)"
python3 -c 'p=".flow/config.yaml"; t=open(p).read(); open(p, "w").write(t.replace("labels: [team-a]", "labels: [team-b]"))'
check_all "ClaimBeforeScopeChanged_KeepsWorktree: an item claimed before it left the scope keeps its worktree, because only a new claim is refused" '[ -n "$held_path" ] && [ "$("$P/scripts/steward.sh" claim "$sin" 2>/dev/null)" = "$held_path" ]'
"$P/scripts/next.sh" "$sin" --json >/dev/null 2>"$work/scope.err"; code=$?
check "NextNamedClaimedBeforeScopeChanged_GetsStep: next on an item claimed before it left the scope prepares its step, because a run under way goes on" [ "$code" -eq 0 ]
end_run "$sin"
"$P/scripts/steward.sh" release "$sin" --force >/dev/null 2>&1
scope_config '    labels: [team-a]'
record set "$sin" step=split >/dev/null; record set "$sout" step=split >/dev/null
: > "$work/scope.procs"; FLOW_HEALTH_PROCS="$work/scope.procs" "$P/scripts/steward.sh" health > "$work/scope.out" 2>&1
check "ScopedHealth_ReportsItemInside: health says a split item inside the scope is the owner's to close, because health reads the scoped list" grep -q "$sin: split, and every child is closed" "$work/scope.out"
check "ScopedHealth_SkipsItemOutside: health says nothing of a split item outside the scope, because it reads the scoped list" sh -c "[ -s '$work/scope.out' ] && ! grep -q '$sout: split' '$work/scope.out'"
record set "$sin" step= >/dev/null; record set "$sout" step= >/dev/null
record set "$sin" pr=https://github.com/acme/widgets/pull/90 >/dev/null; record set "$sout" pr=https://github.com/acme/widgets/pull/90 >/dev/null
mkdir -p "$work/scope/gh" && cp "$P/tests/_fake_gh.py" "$work/scope/gh/"
printf '{"issues": [], "pr": {"number": 90, "state": "OPEN", "isDraft": false, "mergedAt": null, "url": "https://github.com/acme/widgets/pull/90", "headRefName": "flow/local-task-1", "baseRefName": "main", "mergeable": "MERGEABLE", "updatedAt": "2026-11-09T10:00:00Z", "headRefOid": "c0ffee"}}\n' > "$work/scope/gh/issues.json"
cat > "$work/scope/bin/claude" <<EOF_SCOPE_HOST
#!/bin/sh
item="\$(printf '%s\\n' "\$*" | sed -n 's|.*/flow:comments \\([^ ]*\\)\\..*|\\1|p' | head -1)"
"$P/adapters/local/comment.sh" "\$item" --body "Addressed every review thread"
EOF_SCOPE_HOST
chmod +x "$work/scope/bin/claude"
ln -sf "$P/tests/fake-gh.sh" "$work/scope/bin/gh"
PATH="$work/scope/bin:$PATH" FAKE_GH_DIR="$work/scope/gh" FLOW_HEALTH_PROCS="$work/scope.procs" "$P/jobs/comments.sh" claude >/dev/null 2>&1
sin_body="$("$P/adapters/local/read.sh" "$sin" | jget body)"; sout_body="$("$P/adapters/local/read.sh" "$sout" | jget body)"
check "ScopedCommentsJob_AddressesItemInside: an item inside the scope gets the comments pass's reply, because the job reads the scoped list" sh -c 'case "$1" in *"Addressed every review thread"*) true ;; *) false ;; esac' _ "$sin_body"
check "ScopedCommentsJob_SkipsItemOutside: an item outside the scope gets no comments pass reply, because the job reads the scoped list" sh -c 'case "$1" in *"Addressed every review thread"*) case "$2" in *"Addressed every review thread"*) false ;; *) true ;; esac ;; *) false ;; esac' _ "$sin_body" "$sout_body"
scope_config '    query: label:team-a'
FLOW_PLUGIN="$P" "$P/skills/init/scripts/init.sh" --check > "$work/scope.out" 2>&1
check "InitCheck_ScopeQueryOnLocal_IsGap: init --check reports local.scope.query as a gap, because the local tracker has no search of its own" grep -q 'gap: .flow/config.yaml: local.scope.query: the local adapter maps assignee, status, labels and kinds, not query' "$work/scope.out"
scope_config '    trackers: [local]'
FLOW_PLUGIN="$P" "$P/skills/init/scripts/init.sh" --check > "$work/scope.out" 2>&1
check "InitCheck_ScopeTrackers_IsGap: init --check reports local.scope.trackers as a gap, because a scope belongs to its tracker" grep -q 'gap: .flow/config.yaml: local.scope.trackers: a scope belongs to its tracker' "$work/scope.out"
scope_value() { # scope_value <local.scope's value, on the key's own line>
  scope_config '' && python3 -c 'import sys; p=".flow/config.yaml"; t=open(p).read(); open(p, "w").write(t.replace("  scope:\n", "  scope: " + sys.argv[1] + "\n", 1))' "$1"
}
scope_value '"labels = team-a"'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "ScopeValueOnItsKey_ListExitsTwo: a local.scope written as a value is refused, because a scope it cannot read would list every item" [ "$code" -eq 2 ]
scope_value '{labels: [team-a]}'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "ScopeInlineMap_ListExitsTwo: a local.scope written as an inline map is refused, because the config reads no inline map" [ "$code" -eq 2 ]
scope_config '    - team-a'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "ScopeAsList_ListExitsTwo: a local.scope written as a list is refused, because a scope it cannot read would list every item" [ "$code" -eq 2 ]
scope_config '     labels: [team-a]'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "ScopeFieldsThreeSpacesIn_ListExitsTwo: a local.scope whose fields sit three spaces in is refused, because no field of it reads" [ "$code" -eq 2 ]
scope_config '    labels:
    - team-a'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "ScopeFieldListAtItsIndent_ListExitsTwo: a local.scope field whose list sits at the field's own indent is refused, because a field no value of which reads would list every item" [ "$code" -eq 2 ]
"$P/scripts/steward.sh" claim "$sout" >/dev/null 2>&1; code=$?
"$P/scripts/steward.sh" release "$sout" --force >/dev/null 2>&1
check "ScopeFieldListAtItsIndent_ClaimExitsTwo: a new claim under a local.scope field whose list sits at the field's own indent is refused, because an unread field is no unset field" [ "$code" -eq 2 ]
FLOW_PLUGIN="$P" "$P/skills/init/scripts/init.sh" --check > "$work/scope.out" 2>&1
check "InitCheck_ScopeFieldListAtItsIndent_IsGap: init --check reports a local.scope field no value of which reads as a gap, naming the field, because every list of the tracker stops on it" grep -q 'gap: .flow/config.yaml: local.scope.labels' "$work/scope.out"
scope_config '    labels:
      team: team-a'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "ScopeFieldNestedMap_ListExitsTwo: a local.scope field written as a map is refused, because a field no value of which reads would list every item" [ "$code" -eq 2 ]
"$P/scripts/steward.sh" claim "$sout" >/dev/null 2>&1; code=$?
"$P/scripts/steward.sh" release "$sout" --force >/dev/null 2>&1
check "ScopeFieldNestedMap_ClaimExitsTwo: a new claim under a local.scope field written as a map is refused, because an unread field is no unset field" [ "$code" -eq 2 ]
scope_value '"labels = team-a"'
"$P/scripts/steward.sh" claim "$sout" >/dev/null 2>&1; code=$?
"$P/scripts/steward.sh" release "$sout" --force >/dev/null 2>&1
check "ClaimUnderScopeValue_ExitsTwo: a new claim under a local.scope it cannot read is refused, because an unread scope is no missing scope" [ "$code" -eq 2 ]
FLOW_PLUGIN="$P" "$P/skills/init/scripts/init.sh" --check > "$work/scope.out" 2>&1
check "InitCheck_ScopeValueOnItsKey_IsGap: init --check reports a local.scope written as a value as a gap, because every list of the tracker stops on it" grep -q 'gap: .flow/config.yaml: local.scope' "$work/scope.out"
scope_config '    labels: [team-a]' && python3 -c 'p=".flow/config.yaml"; t=open(p).read(); open(p, "w").write(t.replace("  scope:\n", "  \"scope\":\n", 1))'
"$P/scripts/steward.sh" claim "$sout" >/dev/null 2>&1; code=$?
"$P/scripts/steward.sh" release "$sout" --force >/dev/null 2>&1
check "ClaimUnderQuotedScopeKey_ExitsTwo: a new claim of an item outside a local.scope whose key is quoted is refused, because a quoted key is the same scope every list applies" [ "$code" -eq 2 ]
"$P/scripts/next.sh" "$sout" >/dev/null 2>&1; code=$?
scope_unpick "{\"item\": \"$sout\"}"
check "NextNamedUnderQuotedScopeKey_ExitsTwo: next on a named item outside a local.scope whose key is quoted is refused, because a quoted key is the same scope every list applies" [ "$code" -eq 2 ]
scope_quoted() { # scope_quoted <quote> <the local.scope block's lines>: scope_config with the scope key in <quote>
  scope_config "$2" && python3 -c 'import sys; p=".flow/config.yaml"; t=open(p).read(); open(p, "w").write(t.replace("  scope:\n", "  %sscope%s:\n" % (sys.argv[1], sys.argv[1]), 1))' "$1"
}
scope_quoted '"' '    milestone: v1'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "DoubleQuotedScopeKeyUnknownField_ListExitsTwo: a local.scope whose key is in double quotes and names a field the adapter does not map is refused, because a quoted key is checked as the unquoted one is" [ "$code" -eq 2 ]
scope_quoted "'" '    milestone: v1'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "SingleQuotedScopeKeyUnknownField_ListExitsTwo: a local.scope whose key is in single quotes and names a field the adapter does not map is refused, because a quoted key is checked as the unquoted one is" [ "$code" -eq 2 ]
scope_quoted '"' '    labels:
      team: team-a'
"$P/adapters/local/list.sh" >/dev/null 2>&1; code=$?
check "QuotedScopeKeyNestedMapField_ListExitsTwo: a field written as a map under a quoted local.scope key is refused, because a scope it cannot read would list every item" [ "$code" -eq 2 ]
scope_quoted "'" "    'labels': [team-a]"
quoted_scope_ids="$("$P/adapters/local/list.sh" 2>/dev/null | scope_ids)"
check_all "QuotedScopeKeys_ListShowsItemInside: a local.scope with quoted keys lists an item it matches, because a quoted key reads as the unquoted one" 'case " $quoted_scope_ids " in *" $sin "*) true ;; *) false ;; esac'
check_all "QuotedScopeKeys_ListHidesItemOutside: a local.scope with quoted keys leaves out an item outside it, because a quoted key reads as the unquoted one" '[ -n "$quoted_scope_ids" ] && case " $quoted_scope_ids " in *" $sout "*) false ;; *) true ;; esac'
scope_config ''
empty_scope_ids="$("$P/adapters/local/list.sh" 2>/dev/null | scope_ids)"
check_all "ScopeEmpty_ListsEveryItem: an empty local.scope lists the items inside and outside the labels, because an empty scope is unset" 'case " $empty_scope_ids " in *" $sin "*) ;; *) false ;; esac && case " $empty_scope_ids " in *" $sout "*) true ;; *) false ;; esac'
cd "$repo"

[ "$fails" -eq 0 ] && { echo "pick: ok"; exit 0; }
echo "pick: $fails failed"; exit 1

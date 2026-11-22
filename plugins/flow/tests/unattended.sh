#!/bin/sh
# unattended.sh: unattended steps, a session cut by a time-window limit, and the unattended loop.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_worktree_helpers.sh"
echo "unattended steps: the model, the architect, the cache, the usage, a host stop (#65)"
mkdir -p "$work/cost" && cd "$work/cost" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
git worktree add -q --detach ../cost-wt-1 && git worktree add -q --detach ../cost-wt-2
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../cost-wt-1\n  - ../cost-wt-2\nnotify:\n  desktop: false\njobs:\n  claude:\n    model: claude-jobs-x\n    effort: low\n  codex:\n    model: gpt-jobs-y\n    effort: medium\n' > .flow/config.yaml
. "$here/_cost_hosts_fixture.sh"
lastrun() { tail -1 .flow/log/runs.jsonl | jget "$1"; }
mt="$("$P/scripts/new.sh" task "Cost medium" --size M --body "## Acceptance
- [ ] m")"
lt="$("$P/scripts/new.sh" task "Cost large" --size L --body "## Acceptance
- [ ] l")"
out="$("$P/scripts/next.sh" "$mt" --json)"
check_all "architect: an M task's design step runs no architect" '[ "$(printf "%s" "$out" | jget architect)" = no ] && grep -q "^- Architect: no (profile task-M)" "$(printf "%s" "$out" | jget brief)"'
rm -f ".flow/runs/$(item_slug "$mt").json"
out="$("$P/scripts/next.sh" "$lt" --json)"
check_all "architect: an L task's design step runs the architect" '[ "$(printf "%s" "$out" | jget architect)" = yes ] && grep -q "^- Architect: yes (profile task-L)" "$(printf "%s" "$out" | jget brief)"'
rm -f ".flow/runs/$(item_slug "$lt").json"
check "architect: on for L tasks and epics only, a switch for every profile" python3 -c "import json,sys; p=json.load(open(sys.argv[1])); a=p['architect']; assert set(a)==set(p['profiles']) and [k for k in a if a[k]]==['task-L','epic'], a" "$P/profiles.json"
check "architect: the plan skill reads the switch and runs no architect on no" sh -c "grep -q 'architect.<profile>' '$P/skills/plan/SKILL.md' && grep -q 'On no, spawn no architect' '$P/skills/plan/SKILL.md'"
: > "$COST_LOG"
PATH="$cpath" "$P/templates/run-unattended.sh" claude "$mt" --max-steps 1 > "$work/cost.out" 2>&1
check "a step with no agent runs on jobs.claude.model and jobs.claude.effort" grep -q 'claude	.*--model claude-jobs-x --effort low' "$COST_LOG"
check "claude sessions write the 5-minute prompt cache, main and subagents" grep -q 'claude	ttl=5m/5m	-p .*--output-format json' "$COST_LOG"
check_all "the step session is a line in runs.jsonl: item, step, model, effort, usage, cost" '[ "$(lastrun item)" = "$mt" ] && [ "$(lastrun step)" = design ] && [ "$(lastrun model)" = claude-jobs-x ] && [ "$(lastrun effort)" = low ] && [ "$(lastrun usage.input_tokens)" = 120 ] && [ "$(lastrun usage.cache_read_input_tokens)" = 900 ] && [ "$(lastrun cost_usd)" = 0.25 ] && [ "$(lastrun models.0)" = claude-jobs-x ] && [ "$(lastrun exit)" = 0 ]'
check_all "a step line has no job key, so the job readers pass over it" '! tail -1 .flow/log/runs.jsonl | grep -q "\"job\"" && [ "$(python3 -I "$P/scripts/_jobs.py" history .flow/log next 10)" = "No runs of next yet." ]'
check "the host's text reaches the log as text, not as its JSON" sh -c "grep -qx 'did the step' '$work/cost.out' && ! grep -q 'total_cost_usd' '$work/cost.out'"
: > "$COST_LOG"
PATH="$cpath" "$P/templates/run-unattended.sh" claude "$mt" --max-steps 1 >/dev/null 2>&1
check "a step with an agent keeps the roster's model and effort" sh -c "grep -q -- '--model $(agent_model planner) --effort $(agent_effort planner)' '$COST_LOG' && ! grep -q claude-jobs-x '$COST_LOG'"
: > "$COST_LOG"
PATH="$cpath" "$P/templates/run-unattended.sh" codex "$lt" --max-steps 1 >/dev/null 2>&1
check "a step with no agent runs on jobs.codex.model and jobs.codex.effort, as written" grep -q 'codex		exec --json .*-m gpt-jobs-y -c model_reasoning_effort="medium"' "$COST_LOG"
check_all "a codex step line sums the turn usage, with no cost" '[ "$(lastrun model)" = gpt-jobs-y ] && [ "$(lastrun usage.input_tokens)" = 50 ] && [ "$(lastrun usage.cached_input_tokens)" = 20 ] && [ "$(lastrun cost_usd)" = null ]'
"$P/scripts/board.sh" > "$work/cost.board" 2>/dev/null
check_all "board: the spend per item, summed over its step sessions, codex cached input counted once" 'grep -qF "| $mt | \$0.50 | 2 | 2900 |" "$work/cost.board" && grep -qF "| $lt | \$0.00 | 1 | 55 |" "$work/cost.board" && [ "$("$P/scripts/board.sh" --json 2>/dev/null | jget "spend.$mt.sessions")" = 2 ]'
: > "$COST_LOG"
PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; export CLAUDE_CODE_PROMPT_CACHE_TTL=1h; host_run claude . hi' >/dev/null 2>&1
check "a prompt cache TTL the owner exported wins" grep -q 'claude	ttl=1h/5m' "$COST_LOG"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../cost-wt-1\n  - ../cost-wt-2\nnotify:\n  desktop: false\njobs:\n  claude:\n    effort: bogus\n' > .flow/config.yaml
PATH="$cpath" "$P/templates/run-unattended.sh" claude --max-steps 1 > "$work/cost.out" 2>&1; code=$?
check "a jobs effort the host does not take stops the loop before it claims an item" sh -c "[ $code = 2 ] && grep -q 'jobs.claude.effort is bogus' '$work/cost.out' && [ -z \"\$(ls .flow/runs/*.json 2>/dev/null)\" ]"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../cost-wt-1\n  - ../cost-wt-2\nnotify:\n  desktop: false\n' > .flow/config.yaml
for it in "$mt" "$lt"; do "$P/scripts/steward.sh" release "$it" --force >/dev/null 2>&1; "$P/adapters/local/close.sh" "$it" >/dev/null 2>&1; done
cp .flow/config.yaml "$work/config.cost"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../cost-wt-1\n  - ../cost-wt-2\nnotify:\n  desktop: false\njobs:\n  claude:\n    model: claude-jobs-x\n    effort: low\n  codex:\n    model: gpt-jobs-y\n    effort: medium\n' > .flow/config.yaml
steprun() { python3 -c 'import json,sys
r=[json.loads(l) for l in open(".flow/log/runs.jsonl")]
print([x for x in r if x.get("item")==sys.argv[1]][-1][sys.argv[2]])' "$1" "$2"; }
ot="$("$P/scripts/new.sh" task "Once on another model" --size M --body "## Acceptance
- [ ] o")"
ou="$("$P/scripts/new.sh" task "Then on the pair" --size M --body "## Acceptance
- [ ] u")"
: > "$COST_LOG"
PATH="$cpath" "$P/jobs/next.sh" claude "$ot" --max-steps 1 --model claude-once-z --effort high > "$work/cost.out" 2>&1
check_all "next job: --model and --effort reach the host for a step with no agent, over jobs.claude" 'grep -q "^claude	.*--model claude-once-z --effort high" "$COST_LOG" && ! grep -q claude-jobs-x "$COST_LOG" && [ "$(steprun "$ot" step)" = design ] && [ "$(steprun "$ot" model)" = claude-once-z ] && [ "$(steprun "$ot" effort)" = high ]'
: > "$COST_LOG"
PATH="$cpath" "$P/jobs/next.sh" claude "$ou" --max-steps 1 >/dev/null 2>&1
check "next job: --model and --effort hold for their run only: the next run is on jobs.claude again" grep -q "^claude	.*--model claude-jobs-x --effort low" "$COST_LOG"
: > "$COST_LOG"; runs_before="$(wc -l < .flow/log/runs.jsonl | tr -d ' ')"; claims_before="$(ls .flow/runs)"
PATH="$cpath" "$P/jobs/next.sh" claude --max-steps 1 --effort bogus > "$work/cost.out" 2>&1; code=$?
check "next job: an --effort claude does not take is refused, exit 2, before the run touches the tracker" sh -c "[ $code = 2 ] && grep -q 'flow: --effort is bogus; claude takes low, medium, high, xhigh or max, or empty for its default' '$work/cost.out' && [ ! -s '$COST_LOG' ] && [ \"\$(wc -l < .flow/log/runs.jsonl | tr -d ' ')\" = $runs_before ] && [ \"\$(ls .flow/runs)\" = '$claims_before' ]"
PATH="$cpath" "$P/jobs/next.sh" codex --max-steps 1 --effort max > "$work/cost.out" 2>&1; code=$?
check "next job: --effort is checked for the host named: max is a claude effort, not a codex one" sh -c "[ $code = 2 ] && grep -q 'flow: --effort is max; codex takes low, medium, high or xhigh' '$work/cost.out' && [ ! -s '$COST_LOG' ] && [ \"\$(wc -l < .flow/log/runs.jsonl | tr -d ' ')\" = $runs_before ]"
for it in "$ot" "$ou"; do "$P/scripts/steward.sh" release "$it" --force >/dev/null 2>&1; "$P/adapters/local/close.sh" "$it" >/dev/null 2>&1; done
cp "$work/config.cost" .flow/config.yaml
st="$("$P/scripts/new.sh" task "Spends" --size S --body "## Acceptance
- [ ] s")"
: > "$COST_LOG"
FAKE_HOST=budget PATH="$cpath" "$P/templates/run-unattended.sh" claude "$st" --max-steps 3 > "$work/cost.out" 2>&1; code=$?
st_step="$(steprun "$st" step)"
check_all "a spend limit raises the escalation gate at once, naming the cause and the host's line" '[ "$code" = 4 ] && [ "$("$P/adapters/local/read.sh" "$st" | jget state.gate)" = escalation ] && grep -q "claude failed on a spend limit: API Error: 422 .*ExceededBudget" ".flow/gates/$(item_slug "$st").json"'
check "a spend limit is one session: no retry, and no run left for health to resume" sh -c "[ \"\$(grep -c . '$COST_LOG')\" = 1 ] && [ ! -f '.flow/runs/$(item_slug "$st").json' ]"
check_all "the stop names the cause and the item whose gate holds it" '[ "$(jget cause < .flow/log/claude.stopped)" = spend-limit ] && [ "$(jget item < .flow/log/claude.stopped)" = "$st" ]'
check_all "the step line carries the cause" '[ "$(lastrun result | cut -d: -f1)" = spend-limit ]'
s2="$("$P/scripts/new.sh" task "Waits" --size S --body "## Acceptance
- [ ] w")"
: > "$COST_LOG"
PATH="$cpath" "$P/templates/run-unattended.sh" claude --max-steps 1 > "$work/cost.out" 2>&1; code=$?
check "a stopped host starts no new session: the next loop exits 4 before it picks" sh -c "[ $code = 4 ] && [ ! -s '$COST_LOG' ] && grep -q 'claude is stopped since .* on a spend limit' '$work/cost.out' && [ -z \"\$(ls .flow/runs/*.json 2>/dev/null)\" ]"
PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run claude . hi' > /dev/null 2>"$work/cost.err"; code=$?
check "a stopped host starts no session for a job either: host_run refuses, exit 75" sh -c "[ $code = 75 ] && [ ! -s '$COST_LOG' ] && grep -q 'until the gate on $st clears' '$work/cost.err'"
# jobrun <job> <field>: the job's newest line in runs.jsonl.
jobrun() { grep "\"job\":\"$1\"" .flow/log/runs.jsonl | tail -1 | jget "$2"; }
PATH="$cpath" "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check_all "comments job: a host stopped on a spend limit ends the run, its status line saying so" 'jobrun comments result | grep -q "^stopped: claude is stopped since .* on a spend limit"'
printf -- '- a note for the stopped host\n' > "$work/stop-notes.md"
PATH="$cpath" "$P/jobs/intake.sh" claude --notes "$work/stop-notes.md" >/dev/null 2>&1
check_all "intake job: a host stopped on a spend limit ends the run, its status line saying so" 'jobrun intake result | grep -q "^stopped: claude is stopped since .* on a spend limit"'
PATH="$cpath" "$P/jobs/retro.sh" claude >/dev/null 2>&1
check_all "retro job: a host stopped on a spend limit ends the run, its status line saying so" 'jobrun retro result | grep -q "^stopped: claude is stopped since .* on a spend limit"'
check "gate list shows the stopped host" sh -c "'$P/scripts/gate.sh' list | grep -q '	claude	stopped	spend-limit: API Error'"
PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run codex . hi' >/dev/null 2>&1; code=$?
check "a stop on claude leaves codex running" [ "$code" = 0 ]
"$P/scripts/gate.sh" clear "$st" "raised the limit" > "$work/cost.out"
check "clearing the gate that names the stop starts the host again" sh -c "grep -q 'claude starts sessions again' '$work/cost.out' && [ ! -f .flow/log/claude.stopped ]"
: > "$COST_LOG"; PATH="$cpath" "$P/templates/run-unattended.sh" claude "$s2" --max-steps 1 >/dev/null 2>&1
check "after the clear a loop starts sessions again" grep -q 'claude	' "$COST_LOG"
# Health resumes no run a spend limit stopped: the gate ended it. Once cleared, the next run
# continues the item at the step the limit cut short.
PATH="$cpath" "$P/templates/run-unattended.sh" claude "$st" --max-steps 1 >/dev/null 2>&1
check_all "after the clear, the next run continues the item the spend limit stopped, at that step" '[ "$(steprun "$st" step)" = "$st_step" ] && [ -z "$(steprun "$st" result)" ]'
FAKE_HOST=auth PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run codex . hi; echo "cause=$host_cause"' > "$work/cost.out" 2>&1; code=$?
check_all "an auth error on codex outside any item stops codex and tells the owner" 'grep -q "cause=auth" "$work/cost.out" && [ "$(jget cause < .flow/log/codex.stopped)" = auth ] && grep -q "	host-stopped	codex stopped on an auth error: unexpected status 401 Unauthorized" .flow/events.log'
"$P/scripts/gate.sh" clear codex > "$work/cost.out"
check "gate.sh clear <host> starts it again" sh -c "grep -q 'codex starts sessions again' '$work/cost.out' && [ ! -f .flow/log/codex.stopped ]"
FAKE_HOST=auth PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run claude . hi' >/dev/null 2>&1
check_all "a Claude login that does not work is an auth stop" '[ "$(jget cause < .flow/log/claude.stopped)" = auth ] && grep -q "Please run /login" .flow/log/claude.stopped'
"$P/scripts/gate.sh" clear claude >/dev/null
FAKE_HOST=errors PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run claude . hi' > "$work/cost.out" 2>/dev/null
check_all "a Claude error result with its words in errors, not result, is logged and stops the host" 'grep -q "Credit balance is too low" "$work/cost.out" && [ "$(jget cause < .flow/log/claude.stopped)" = spend-limit ]'
"$P/scripts/gate.sh" clear claude >/dev/null
FAKE_HOST=model PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run claude . hi' >/dev/null 2>&1
check_all "a model claude does not know stops claude, naming the model" '[ "$(jget cause < .flow/log/claude.stopped)" = model ] && grep -q "claude-nope-9" .flow/log/claude.stopped && grep -q "	host-stopped	claude stopped on an unknown model: .*claude-nope-9" .flow/events.log'
"$P/scripts/gate.sh" clear claude >/dev/null
FAKE_HOST=model PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run codex . hi' >/dev/null 2>&1
check_all "a model codex does not have stops codex, naming the model" '[ "$(jget cause < .flow/log/codex.stopped)" = model ] && grep -q "gpt-nope-9" .flow/log/codex.stopped'
"$P/scripts/gate.sh" clear codex >/dev/null
FAKE_HOST=other PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run claude . hi' >/dev/null 2>&1; code=$?
FAKE_HOST=quote PATH="$cpath" sh -c '. "$FLOW_PLUGIN/lib/host.sh"; host_run claude . hi' >/dev/null 2>&1
check "another failure, or a good session that quotes a limit, stops nothing" sh -c "[ $code = 1 ] && [ ! -f .flow/log/claude.stopped ]"

echo "a session cut by a time-window limit"
mkdir -p "$work/window"
window_seen="You've hit your 5-hour limit · resets 5:10am (Europe/London)"
for window_line in "$window_seen" \
                   "You've hit your limit · resets 5:10am (Europe/London)" \
                   "You've hit your weekly limit · resets Mon 9:00am (Europe/London)" \
                   "You've hit your daily limit · resets 12:00am (UTC)" \
                   "You've hit your 12-hour limit · resets 3:45pm (America/New_York)"; do
  FAKE_HOST=window FAKE_HOST_SAID="$window_line" "$work/costbin/claude" > "$work/window/out"
  : > "$work/window/err"
  python3 -I "$P/scripts/_host.py" claude "$work/window/out" "$work/window/err" 1 "$work/window/sum" >/dev/null 2>&1
  check "TimeWindowLimit_IsSpendLimit: a session ended on \"$window_line\" has cause spend-limit, because the host is out of spend until the window resets" \
    [ "$(jget cause < "$work/window/sum")" = spend-limit ]
done
for window_stream in out err; do
  : > "$work/window/out"; : > "$work/window/err"
  printf '%s\n' "$window_seen" > "$work/window/$window_stream"
  python3 -I "$P/scripts/_host.py" claude "$work/window/out" "$work/window/err" 1 "$work/window/sum" >/dev/null 2>&1
  check "TimeWindowLimit_AsPlainLineOnStd$window_stream: a time-window line outside the result object, on std$window_stream, has cause spend-limit, because a session cut early may print no result" \
    [ "$(jget cause < "$work/window/sum")" = spend-limit ]
done
python3 -c 'import json,sys; print(json.dumps({"type":"result","subtype":"success","is_error":False,"result":"Done. The old log said: "+sys.argv[1],"total_cost_usd":0}))' "$window_seen" > "$work/window/out"
: > "$work/window/err"
python3 -I "$P/scripts/_host.py" claude "$work/window/out" "$work/window/err" 0 "$work/window/sum" >/dev/null 2>&1
check_all "TimeWindowLimit_QuotedByGoodSession_HasNoCause: a session that ends well and quotes a time-window line has no cause, because only a failed session can stop the host" \
  '[ -s "$work/window/sum" ] && [ "$(jget cause < "$work/window/sum")" = "" ]'
window_loop_folder="$work/windowloop"
window_loop_repo="$window_loop_folder/app"
mkdir -p "$window_loop_folder" && git init -q -b main "$window_loop_repo"
(cd "$window_loop_repo" && git config user.email t@t && git config user.name t \
  && printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow \
  && git worktree add -q --detach ../window-loop-wt-1 \
  && printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../window-loop-wt-1\nnotify:\n  desktop: false\n' > .flow/config.yaml)
window_attempts_max="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_attempts"])' "$P/profiles.json")"
window_loop_item="$(cd "$window_loop_repo" && "$P/scripts/new.sh" task "Cut by the 5-hour window" --size S --body "## Acceptance
- [ ] w")"
window_loop_attempts="$(cd "$window_loop_repo" && "$P/adapters/local/read.sh" "$window_loop_item" | jget state.attempts)"
(cd "$window_loop_repo" && FAKE_HOST=window FAKE_HOST_SAID="$window_seen" PATH="$cpath" "$P/templates/run-unattended.sh" claude "$window_loop_item" --max-steps "$window_attempts_max" > "$work/windowloop.out" 2>&1)
window_loop_stopped="$window_loop_repo/.flow/log/claude.stopped"
window_loop_gate="$window_loop_repo/.flow/gates/$(item_slug "$window_loop_item").json"
check "TimeWindowLimit_KeepsAttemptCount: a step cut by a time-window limit keeps its attempt count, because the limit is the host's, not the step's" \
  [ "$(cd "$window_loop_repo" && "$P/adapters/local/read.sh" "$window_loop_item" | jget state.attempts)" = "$window_loop_attempts" ]
check "TimeWindowLimit_RecordsOneSession: a time-window limit is one step session in runs.jsonl, no retry, because every retry before the reset fails the same way" \
  python3 -I -c 'import json,sys; sessions=[json.loads(line) for line in open(sys.argv[1]) if line.strip()]; sys.exit([session["item"] for session in sessions] != [sys.argv[2]])' "$window_loop_repo/.flow/log/runs.jsonl" "$window_loop_item"
check_all "TimeWindowLimit_StopsHostOnSpendLimit: the host is stopped on a spend limit, because no session can run until the window resets" \
  '[ "$(jget cause < "$window_loop_stopped")" = spend-limit ]'
check_all "TimeWindowLimit_StopsHostWithItsLine: the stopped host keeps the host's line, because it says when the window resets" \
  '[ "$(jget said < "$window_loop_stopped")" = "$window_seen" ]'
check_all "TimeWindowLimit_GateQuotesHostLine: the item's gate quotes the host's line, because it says when the window resets" \
  'jget message < "$window_loop_gate" | grep -qF "$window_seen"'
check_all "TimeWindowLimit_GateIsNotAttemptLimit: the item's gate is not the attempt limit's escalation, because no attempt failed" \
  '[ -f "$window_loop_gate" ] && ! jget message < "$window_loop_gate" | grep -qE "Step [a-z-]+ failed [0-9]+ times"'

echo "unattended loop: a pick works on after a gate"
# A plugin copy whose next.sh hands out the items in $GL/queue (a named one as asked) and whose
# advance.sh exits with the code in $GL/advance.<slug> (0 when none); the gate it stands for is the
# record the test writes in .flow/gates. The hosts are the stubs above.
GL="$work/gl"; export GL; mkdir -p "$GL"
glp="$work/plugin-gl"; cp -R "$P" "$glp"; rm -rf "$glp/evals/results"
cat > "$glp/scripts/next.sh" <<'STUB'
#!/bin/sh
item=""; for a in "$@"; do case "$a" in --*) ;; *) item="$a" ;; esac; done
if [ -z "$item" ]; then
  item="$(head -1 "$GL/queue")"; [ -n "$item" ] || { echo "nothing ready" >&2; exit 5; }
  tail -n +2 "$GL/queue" > "$GL/queue.tmp"; mv "$GL/queue.tmp" "$GL/queue"
fi
echo "next $item" >> "$GL/calls"
printf '{"item":"%s","worktree":"%s","brief":"%s/brief.md","step":"implement","agent":"","model":"","effort":"","skill":""}\n' "$item" "$GL" "$GL"
STUB
cat > "$glp/scripts/advance.sh" <<'STUB'
#!/bin/sh
echo "advance $1" >> "$GL/calls"
exit "$(cat "$GL/advance.$(printf '%s' "$1" | tr ':/#' '---')" 2>/dev/null || echo 0)"
STUB
chmod +x "$glp/scripts/next.sh" "$glp/scripts/advance.sh"
gi1="$("$P/scripts/new.sh" task "Gate one" --size S --body x)"; gi2="$("$P/scripts/new.sh" task "Gate two" --size S --body x)"
# gl_case <items for the queue> -- <item>=<advance exit>[:<gate>]...: a fresh queue, calls and gates.
gl_case() {
  : > "$GL/calls"; rm -f "$GL"/advance.* .flow/gates/*.json; : > "$GL/queue"
  while [ $# -gt 0 ] && [ "$1" != -- ]; do echo "$1" >> "$GL/queue"; shift; done; shift
  for spec in "$@"; do
    it="${spec%%=*}"; rest="${spec#*=}"; slug="$(item_slug "$it")"
    echo "${rest%%:*}" > "$GL/advance.$slug"
    case "$rest" in *:*) mkdir -p .flow/gates; printf '{"gate":"%s","item":"%s"}\n' "${rest#*:}" "$it" > ".flow/gates/$slug.json" ;; esac
  done
}
gl_calls() { tr '\n' '|' < "$GL/calls"; }
gl_case "$gi1" "$gi2" -- "$gi1=4:plan-approval" "$gi2=4:merge"
FLOW_PLUGIN="$glp" PATH="$cpath" "$glp/templates/run-unattended.sh" claude --max-steps 5 > "$work/gl.out" 2>&1; code=$?
check_all "unattended loop: a picked item at a gate is set down and the next ready one picked, until nothing is left" '[ "$(gl_calls)" = "next $gi1|advance $gi1|next $gi2|advance $gi2|" ] && grep -q "$gi1 waits at the plan-approval gate; picking another item" "$work/gl.out"'
check_all "unattended loop: a run that reached a gate and then found nothing ends as a gate, exit 4, with its steps" '[ "$code" = 4 ] && tail -1 "$work/gl.out" | grep -q "stopped at a gate: 2 item(s) reached one in 2 step(s), then next.sh had nothing to start (exit 5)"'
gl_case "$gi1" "$gi2" -- "$gi1=4:plan-approval"
FLOW_PLUGIN="$glp" PATH="$cpath" "$glp/templates/run-unattended.sh" claude --max-steps 1 > "$work/gl.out" 2>&1; code=$?
check_all "unattended loop: a gate on the last step the budget allows ends as a gate" '[ "$code" = 4 ] && [ "$(gl_calls)" = "next $gi1|advance $gi1|" ] && tail -1 "$work/gl.out" | grep -q "stopped at a gate: 1 item(s) reached one in 1 step(s), the step budget"'
gl_case "$gi2" -- "$gi1=4:plan-approval"
FLOW_PLUGIN="$glp" PATH="$cpath" "$glp/templates/run-unattended.sh" claude "$gi1" --max-steps 5 > "$work/gl.out" 2>&1; code=$?
check_all "unattended loop: a named item stops at its gate, nothing else picked" '[ "$code" = 4 ] && [ "$(gl_calls)" = "next $gi1|advance $gi1|" ] && tail -1 "$work/gl.out" | grep -q "stopped (exit 4)"'
gl_case "$gi1" "$gi2" -- "$gi1=4:escalation"
FLOW_PLUGIN="$glp" PATH="$cpath" "$glp/templates/run-unattended.sh" claude --max-steps 5 > "$work/gl.out" 2>&1; code=$?
check_all "unattended loop: a pick that escalates ends the run" '[ "$code" = 4 ] && [ "$(gl_calls)" = "next $gi1|advance $gi1|" ]'
gl_case "$gi1" "$gi2" --
FAKE_HOST=budget FLOW_PLUGIN="$glp" PATH="$cpath" "$glp/templates/run-unattended.sh" claude --max-steps 5 > "$work/gl.out" 2>&1; code=$?
check_all "unattended loop: a host stop on a pick ends the run at its escalation gate" '[ "$code" = 4 ] && [ "$(gl_calls)" = "next $gi1|" ] && grep -q "$gi1 stopped at an escalation gate" "$work/gl.out"'
"$P/scripts/gate.sh" clear "$gi1" "limit raised" >/dev/null 2>&1
gl_case "$gi1" "$gi2" -- "$gi1=4:plan-approval" "$gi2=4:merge"
FLOW_PLUGIN="$glp" PATH="$cpath" "$glp/jobs/next.sh" claude --max-steps 5 >/dev/null 2>&1; code=$?
check_all "next job: a run that worked past a gate says it stopped at a gate, with every step it ran" '[ "$code" = 0 ] && tail -1 .flow/log/next.log | grep -q "stopped at a gate (see .*/gates), 2 steps\$"'
rm -f .flow/gates/*.json
for it in "$gi1" "$gi2"; do "$P/adapters/local/close.sh" "$it" >/dev/null 2>&1; done

[ "$fails" -eq 0 ] && { echo "unattended: ok"; exit 0; }
echo "unattended: $fails failed"; exit 1

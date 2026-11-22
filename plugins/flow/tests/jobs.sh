#!/bin/sh
# jobs.sh: the jobs on fake hosts, and the run ledger, pause and the schedule through a fake
# launchctl.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_github_fixture.sh"
. "$here/_review_fixture.sh"
. "$here/_comments_job_fixture.sh"
echo "jobs (fake hosts)"
. "$here/_jobs_fixture.sh"
"$P/adapters/github/write-state.sh" 'gh#21' step=pr && "$P/adapters/github/link-pr.sh" 'gh#21' https://gh/pull/90
"$P/jobs/comments.sh" claude >/dev/null
check "comments job: runs the skill per open PR from the main worktree when the item holds none" sh -c "grep -q 'claude	$realrepo	-p /flow:comments gh#21' '$HOST_LOG' && grep -q 'addressing gh#21' .flow/log/comments.log"
check "comments job: one PR, one run" [ "$(grep -c comments "$HOST_LOG")" = "1" ]
check "comments job: a mergeable PR gets no conflict note" sh -c "! grep -q 'Conflicts step' '$HOST_LOG'"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a PR with nothing new since the last pass is skipped, quiet" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: nothing new since the last pass, skipped' .flow/log/comments.log && tail -1 .flow/log/comments.log | grep -q 'quiet: nothing new on 1 PR(s)'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['updatedAt']='2026-10-24T16:06:00Z'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a new comment on the PR starts a pass" grep -q 'comments gh#21' "$HOST_LOG"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "comments job: a named PR runs even with nothing new" grep -q 'comments gh#21' "$HOST_LOG"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/claude"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['updatedAt']='2026-10-24T16:30:00Z'; json.dump(d, open(p,'w'))"
"$P/jobs/comments.sh" claude >/dev/null
printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' > "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a pass the host failed is tried again" grep -q 'comments gh#21' "$HOST_LOG"
check "comments job: a failed pass is recorded as failed, not done" sh -c "grep -q 'gh#21: pass failed, host exit 1; the next run tries it again' .flow/log/comments.log && grep -q '\"exit\":1,\"result\":\"failed: gh#21 cut short or failed' .flow/log/runs.jsonl"
okhost='#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n'
bump() { python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['updatedAt']='$1'; json.dump(d, open(p,'w'))"; }
# The host stopping the addresser at its background-task ceiling exits 0, and is still a failed pass.
printf "$okhost"'echo "Background tasks still running 10m after the last turn (subagent \\"Address review thread\\"); stopping them. Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely."\necho "The addresser is working on the one open thread."\n' > "$work/bin/claude"
bump 2026-10-24T16:40:00Z
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null; code=$?
check "comments job: a pass the host cut short at its background ceiling is failed, exit 1" sh -c "[ $code -eq 1 ] && grep -q 'gh#21: pass failed, the host stopped the addresser before it finished' .flow/log/comments.log && tail -1 .flow/log/comments.log | grep -q 'failed: gh#21'"
resume_md="$("$P/scripts/steward.sh" reports 'gh#21')/comments-resume.md"
check "comments job: a cut-short pass leaves the next pass a resume note" sh -c "grep -q 'The previous comments pass on PR #90 was cut short at .*Read git status and git diff, continue from there' '$resume_md'"
check "comments job: the host's output reaches the log as the pass runs" grep -q 'The addresser is working on the one open thread.' .flow/log/comments.log
check "comments job: the output file goes with the run" sh -c "! ls .flow/log/comments.out.* >/dev/null 2>&1"
printf "$okhost" > "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a cut-short pass is tried again with nothing new, told to read the note" sh -c "grep -q 'comments gh#21' '$HOST_LOG' && grep -q 'An earlier pass was cut short: read .*comments-resume.md first' '$HOST_LOG'"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the retry that finished is the last pass, so the next run is quiet" [ ! -s "$HOST_LOG" ]
check "comments job: the pass that completed removes the resume note" [ ! -f "$resume_md" ]
printf "$okhost"'echo "Done. The log quoted: Background tasks still running 10m after the last turn; stopping them."\n' > "$work/bin/claude"
bump 2026-10-24T16:45:00Z
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null; code=$?
check "comments job: a good pass whose text quotes the ceiling line is not failed" sh -c "[ $code -eq 0 ] && tail -1 .flow/log/comments.log | grep -q 'done: 1 PR(s)'"
# Failures in a row with nothing changing: three tries, then the PR waits and the owner is told once.
printf '#!/bin/sh\nexit 1\n' > "$work/bin/claude"; bump 2026-10-24T16:50:00Z
for n in 1 2 3; do "$P/jobs/comments.sh" claude >/dev/null; done
printf "$okhost" > "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: after three failed passes in a row the job stops trying the PR" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: 3 passes in a row failed, skipped until a pass run by hand completes' .flow/log/comments.log"
check "comments job: the owner is told once about the failing PR" [ "$(grep -c 'comments	gh#21: the comments pass failed 3 times in a row' .flow/events.log)" = 1 ]
check "comments job: the result line says the failing PR waits on the owner" sh -c "tail -1 .flow/log/comments.log | grep -q 'quiet: 1 wait on you: gh#21 (3 passes in a row failed)\$'"
bump 2026-10-24T16:55:00Z; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: activity a cut-short pass may have made does not restart the retries" [ ! -s "$HOST_LOG" ]
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a pass run by hand that completes lets the job try the PR again" sh -c "[ \"\$(grep -c 'comments gh#21' '$HOST_LOG')\" = 1 ] && tail -1 .flow/log/comments.log | grep -q 'quiet: nothing new'"
# An unresolved thread whose last word is not the flow's reply waits on a pass.
python3 - "$FAKE_GH_DIR/issues.json" <<'PY3'
import json, sys
d = json.load(open(sys.argv[1]))
d["threads"] = [{"id": "T_9", "isResolved": False, "isOutdated": False, "path": "src/R.cs", "line": 7,
                 "comments": {"nodes": [{"databaseId": 901, "body": "This drops the slide.", "author": {"login": "chatgpt-codex-connector"}, "createdAt": "t"}]}}]
json.dump(d, open(sys.argv[1], "w"))
PY3
check "activity: counts the unresolved threads, their comments and the last comment of the ones awaiting us" sh -c "'$P/scripts/comments.sh' activity 90 | python3 -c 'import json,sys; a=json.load(sys.stdin); assert (a[\"unresolved\"],a[\"review_comments\"],a[\"awaiting\"])==(1,1,[901]), a'"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a new review thread starts a pass" grep -q 'comments gh#21' "$HOST_LOG"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a thread still awaiting a reply gets one more pass" sh -c "grep -q 'comments gh#21' '$HOST_LOG' && grep -q 'gh#21: open thread(s) 901 still wait on a reply, one more pass' .flow/log/comments.log"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: then the same awaiting threads are skipped, and the owner told once" sh -c "[ ! -s '$HOST_LOG' ] && [ \"\$(grep -c 'comments	gh#21: review thread(s) on .* still wait on a reply after two passes' .flow/events.log)\" = 1 ]"
check "comments job: the result line says the PR waits on the owner and why, not that nothing is new" sh -c "tail -1 .flow/log/comments.log | grep -q 'quiet: 1 wait on you: gh#21 (thread(s) 901 unanswered after two passes)\$'"
# The extra pass a stopped host refuses is not spent: after the clear it runs.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads'][0]['comments']['nodes'].append({'databaseId': 904, 'body': 'Still drops it.', 'author': {'login': 'chatgpt-codex-connector'}, 'createdAt': 't'}); json.dump(d, open(p,'w'))"
"$P/jobs/comments.sh" claude >/dev/null
FLOW_HOST_GATES=1 sh -c '. "$FLOW_PLUGIN/lib/flow.sh"; . "$FLOW_PLUGIN/lib/host.sh"; host_stop claude spend-limit "API Error: 422 ExceededBudget"'
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a stopped host refuses the extra pass" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: open thread(s) 904 still wait on a reply, one more pass' .flow/log/comments.log"
"$P/scripts/gate.sh" clear claude >/dev/null
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the extra pass a stopped host refused runs after the clear" grep -q 'comments gh#21' "$HOST_LOG"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads'][0]['comments']['nodes'].pop(); json.dump(d, open(p,'w'))"
check "activity: a reply from before 1.19.0 (no marker) by the flow's login is ours" sh -c "python3 - '$FAKE_GH_DIR/issues.json' <<'PY5'
import json, sys
d = json.load(open(sys.argv[1]))
d['threads'].append({'id': 'T_10', 'isResolved': False, 'isOutdated': False, 'path': 'src/S.cs', 'line': 1,
                     'comments': {'nodes': [{'databaseId': 1001, 'body': 'Rename this.', 'author': {'login': 'chatgpt-codex-connector'}, 'createdAt': 't'},
                                            {'databaseId': 1002, 'body': 'Renamed in abc.', 'author': {'login': 'owner'}, 'createdAt': 't'}]}})
json.dump(d, open(sys.argv[1], 'w'))
PY5
'$P/scripts/comments.sh' activity 90 | grep -q '\"awaiting\": \[901\]'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads']=d['threads'][:1]; json.dump(d, open(p,'w'))"
"$P/scripts/comments.sh" reply 90 901 "Kept the slide, as the owner asked."
check "reply: the flow's reply carries its marker" sh -c "python3 -c \"import json; d=json.load(open('$FAKE_GH_DIR/issues.json')); assert '<!-- flow:reply -->' in d['threads'][0]['comments']['nodes'][-1]['body']\""
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: our reply on the thread counts as new once" grep -q 'comments gh#21' "$HOST_LOG"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a thread whose last word is the flow's reply waits on the reviewer, skipped" sh -c "[ ! -s '$HOST_LOG' ] && tail -1 .flow/log/comments.log | grep -q 'quiet: nothing new on 1 PR(s)'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads'][0]['comments']['nodes'].append({'databaseId': 902, 'body': 'Keep it: I want the slide.', 'author': {'login': 'owner'}, 'createdAt': 't'}); json.dump(d, open(p,'w'))"
check "activity: the owner's reply under the flow's login, after a marked reply, awaits a reply" sh -c "'$P/scripts/comments.sh' activity 90 | grep -q '\"awaiting\": \[902\]'"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the owner's answer on the thread starts a pass" grep -q 'comments gh#21' "$HOST_LOG"
# An item at a gate (not merge) is the owner's: no pass, even with a thread awaiting.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads'][0]['comments']['nodes'].append({'databaseId': 903, 'body': 'And this?', 'author': {'login': 'chatgpt-codex-connector'}, 'createdAt': 't'}); json.dump(d, open(p,'w'))"
"$P/adapters/github/write-state.sh" 'gh#21' gate=ambiguity
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: an item waiting at a gate is skipped, threads or not" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: waits at the ambiguity gate, skipped' .flow/log/comments.log"
check "comments job: the result line names the PR at a gate" sh -c "tail -1 .flow/log/comments.log | grep -q 'quiet: no open PR to address; at a gate: gh#21 (ambiguity gate)\$'"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "comments job: a named PR runs at a gate" grep -q 'comments gh#21' "$HOST_LOG"
"$P/adapters/github/write-state.sh" 'gh#21' gate=merge
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the merge gate does not stop a pass" grep -q 'comments gh#21' "$HOST_LOG"
"$P/adapters/github/write-state.sh" 'gh#21' gate=none
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads']=[]; json.dump(d, open(p,'w'))"
# A pass that stops at a gate leaves the PR as it was: the owner clearing the gate is what is new.
"$P/jobs/comments.sh" claude >/dev/null; "$P/adapters/github/write-state.sh" 'gh#21' gate=escalation
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: an item at the escalation gate is skipped as gated" sh -c "[ ! -s '$HOST_LOG' ] && tail -2 .flow/log/comments.log | grep -q 'gh#21: waits at the escalation gate, skipped'"
"$P/scripts/gate.sh" clear 'gh#21' "carry on" >/dev/null
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a cleared gate is new activity, so the item is picked up again" grep -q 'comments gh#21' "$HOST_LOG"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the clear counts once: the run after it finds nothing new" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: nothing new since the last pass, skipped' .flow/log/comments.log"
# gh#157: a gate a comments pass raised on an item past its last step. Its PR is open, so the
# comments job owns the answer: the clear says so, the board shows it waiting, and the next pass
# carries it in its brief and takes it once the pass confirms it carried it out.
"$P/adapters/github/write-state.sh" 'gh#21' step=done
"$P/scripts/gate.sh" raise 'gh#21' ambiguity "1. Merge main into epic/525 first?" >/dev/null 2>&1
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['state']='MERGED'; json.dump(d, open(p,'w'))"
"$P/scripts/gate.sh" clear 'gh#21' "Go with a, merge main into epic/525" > "$work/answer.out" 2>&1; code=$?
check_all "clear at done with a merged PR: refused out loud, as no comments pass comes, and the gate stays" '[ "$code" = 1 ] && grep -q "no step acts on this answer: gh#21 is done and its PR .* is merged" "$work/answer.out" && [ "$("$P/adapters/github/read.sh" "gh#21" | jget state.gate)" = ambiguity ]'
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['state']='OPEN'; json.dump(d, open(p,'w'))"
"$P/scripts/gate.sh" clear 'gh#21' "Go with a, merge main into epic/525" > "$work/answer.out" 2>&1; code=$?
check_all "clear at done with an open PR: the answer waits on the comments job, and the clear says so, not next" '[ "$code" = 0 ] && [ "$("$P/adapters/github/read.sh" "gh#21" | jget state.answer_pending)" = comments ] && grep -q "the comments job" "$work/answer.out" && ! grep -q "run next" "$work/answer.out"'
check "board: an answer that waits on the comments job shows on its item" sh -c "'$P/scripts/board.sh' | grep -q '| gh#21 | .* | none, answer waits on the comments job |'"
# Fake passes: one that only logs (it carried nothing out), and one that confirms the answer the
# way the skill's Answer step does, writing the line the brief names to the file it names.
cp "$work/bin/claude" "$work/claude.before"
printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' > "$work/bin/claude"
cat > "$work/confirm-host" <<'HOST'
#!/bin/sh
printf '%s\t%s\t%s\n' "$0" "$PWD" "$*" >> "$HOST_LOG"
rec="$(printf '%s' "$*" | sed -n 's/.*write the line \([^ ]*\) to \([^ ]*\)\. .*/\1 \2/p')"
[ -z "$rec" ] || printf '%s\n' "${rec%% *}" > "${rec#* }"
HOST
chmod +x "$work/confirm-host"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the owner's answer goes in the pass's brief" grep -q "comments gh#21.* The owner answered the ambiguity gate: Go with a, merge main into epic/525\. Run the Answer step first; once it is carried out or raised again as a gate, write the line 20[0-9T:-]*Z to .*\.answer\." "$HOST_LOG"
check_all "comments job: a pass that ends without confirming the answer leaves it pending, and counts as failed" '[ "$("$P/adapters/github/read.sh" "gh#21" | jget state.answer_pending)" = comments ] && grep -q "gh#21: pass failed, the pass did not confirm it carried out the owner.s answer" .flow/log/comments.log'
cp "$work/confirm-host" "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a pass that confirms it carried the answer out takes it" [ -z "$("$P/adapters/github/read.sh" 'gh#21' | jget state.answer_pending)" ]
"$P/adapters/github/write-state.sh" 'gh#21' answer_pending=comments
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: an answer still waiting gets a pass though nothing else on the PR is new" grep -q "comments gh#21.* The owner answered the ambiguity gate" "$HOST_LOG"
# The owner clears a newer gate while the pass runs (gate.sh clear takes no item lock): the pass
# confirms the answer it was given, and the newer one still waits for the next pass.
"$P/adapters/github/write-state.sh" 'gh#21' answer_pending=comments
{ cat "$work/confirm-host"; printf '"%s/adapters/github/write-state.sh" "gh#21" answered_at=2026-11-09T09:00:00Z "answer=Merge it by hand after all" answer_pending=comments >/dev/null\n' "$P"; } > "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check_all "comments job: a newer answer that came while the pass ran is not taken with the old one" '[ "$("$P/adapters/github/read.sh" "gh#21" | jget state.answer_pending)" = comments ] && grep -q "gh#21: a newer answer to its gate came while the pass ran" .flow/log/comments.log'
cp "$work/confirm-host" "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check_all "comments job: the next pass carries the newer answer and takes it" 'grep -q "comments gh#21.* The owner answered the ambiguity gate: Merge it by hand after all\. .*write the line 2026-11-09T09:00:00Z to" "$HOST_LOG" && [ -z "$("$P/adapters/github/read.sh" "gh#21" | jget state.answer_pending)" ]'
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a taken answer is not briefed again" sh -c "! grep -q 'The owner answered' '$HOST_LOG'"
cp "$work/claude.before" "$work/bin/claude"
"$P/adapters/github/write-state.sh" 'gh#21' step=pr
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['mergeable']='CONFLICTING'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a PR that conflicts with its base is named in the brief" grep -q 'gh#21. The PR conflicts with its base main: run the Conflicts step first.' "$HOST_LOG"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['baseRefName']='main;touch x'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a base name with shell characters never reaches the brief" sh -c "! grep -q 'touch x' '$HOST_LOG' && grep -q 'conflicts with a base named oddly' .flow/log/comments.log"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['baseRefName']='main'; d['pr']['mergeable']='MERGEABLE'; json.dump(d, open(p,'w'))"
# Checks on the head: the latest run of each check counts; one red check gets one pass, not a loop.
rollup() { python3 - "$FAKE_GH_DIR/issues.json" "$1" <<'PY6'
import json, sys
d = json.load(open(sys.argv[1])); d["pr"]["headRefOid"] = "c0ffee1234567890"
run = lambda name, status, conclusion, started: {"__typename": "CheckRun", "name": name, "workflowName": "ci", "status": status,
                                                  "conclusion": conclusion, "startedAt": started}
status = lambda context, state: {"__typename": "StatusContext", "context": context, "state": state, "startedAt": "2026-11-01T10:00:00Z"}
d["pr"]["statusCheckRollup"] = {
    "green": [run("build", "COMPLETED", "SUCCESS", "2026-11-01T10:00:00Z"), run("lint", "COMPLETED", "SKIPPED", "2026-11-01T10:00:00Z"),
              status("deploy/preview", "SUCCESS")],
    "red": [run("test (macos)", "COMPLETED", "FAILURE", "2026-11-01T10:00:00Z"), run("build", "COMPLETED", "SUCCESS", "2026-11-01T10:00:00Z"),
            status("deploy/preview", "ERROR"), run("lint", "IN_PROGRESS", "", "2026-11-01T10:00:00Z"), status("ci/expected", "EXPECTED")],
    "rerun-passed": [run("test (macos)", "COMPLETED", "FAILURE", "2026-11-01T10:00:00Z"), run("test (macos)", "COMPLETED", "SUCCESS", "2026-11-01T11:00:00Z")],
    "rerun-queued": [run("test (macos)", "COMPLETED", "FAILURE", "2026-11-01T10:00:00Z"), run("test (macos)", "QUEUED", None, "0001-01-01T00:00:00Z")],
    "rerun-failed": [run("test (macos)", "COMPLETED", "SUCCESS", "2026-11-01T10:00:00Z"), run("test (macos)", "COMPLETED", "TIMED_OUT", "2026-11-01T11:00:00Z")],
    "none": [],
}[sys.argv[2]]
json.dump(d, open(sys.argv[1], "w"))
PY6
}
rollup green
check "failing-checks: nothing when every check passed or was skipped" [ -z "$("$P/scripts/comments.sh" failing-checks 90)" ]
rollup none
check "failing-checks: nothing when the head has no checks" [ -z "$("$P/scripts/comments.sh" failing-checks 90)" ]
rollup rerun-passed
check "failing-checks: a failed check whose re-run passed does not count" [ -z "$("$P/scripts/comments.sh" failing-checks 90)" ]
rollup rerun-queued
check "failing-checks: a failed check whose re-run has not started yet waits" [ -z "$("$P/scripts/comments.sh" failing-checks 90)" ]
rollup rerun-failed
check "failing-checks: a passed check whose re-run failed counts" [ "$("$P/scripts/comments.sh" failing-checks 90)" = "test (macos)" ]
rollup red
check "failing-checks: the failed check runs and statuses, one per line, sorted; pending ones wait" [ "$("$P/scripts/comments.sh" failing-checks 90 | tr '\n' '|')" = "deploy/preview|test (macos)|" ]
check "activity: lists the failing checks" sh -c "'$P/scripts/comments.sh' activity 90 | python3 -c 'import json,sys; a=json.load(sys.stdin); assert a[\"failing\"]==[\"deploy/preview\",\"test (macos)\"], a'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].pop('statusCheckRollup'); json.dump(d, open(p,'w'))"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null; line_before="$(cat .flow/log/comments.seen/gh_21)"
rollup green; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a PR with no failing check keeps the activity line it had before, so no extra pass" sh -c "[ ! -s '$HOST_LOG' ] && [ \"\$(cat .flow/log/comments.seen/gh_21)\" = '$line_before' ]"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "comments job: green checks put no checks note in the brief" sh -c "grep -q 'comments gh#21' '$HOST_LOG' && ! grep -q 'Checks step' '$HOST_LOG'"
rollup red; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a check gone red on the same head starts a pass" grep -q 'comments gh#21' "$HOST_LOG"
check "comments job: the brief names the failing checks and the head" grep -q 'gh#21. Checks fail on c0ffee12: deploy/preview, test (macos): run the Checks step, then the threads whatever it finds.' "$HOST_LOG"
check "comments job: the activity line closes on the failing checks" sh -c "grep -q ' failing:deploy/preview,test (macos)\$' .flow/log/comments.seen/gh_21"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a red check the pass could not fix is not tried again on the same head" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: nothing new since the last pass, skipped' .flow/log/comments.log"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].pop('statusCheckRollup'); d['pr'].pop('headRefOid'); json.dump(d, open(p,'w'))"
: > "$HOST_LOG"
"$P/jobs/comments.sh" codex >/dev/null
check "comments job on codex: exec in the main worktree" sh -c "grep -q 'codex	.*	exec --json -C $realrepo -s workspace-write' '$HOST_LOG'"
check "CommentsJobOnCodex_StartsItsSkillAsPluginColonSkill: the codex pass starts with \$flow:comments gh#21, because Codex starts a plugin's skill only when the prompt names it as \$plugin:skill" sh -c "grep -q 'codex	.*workspace-write.* \\\$flow:comments gh#21' '$HOST_LOG'"
check "HostSkillPrompt_CodexSkill_PrefixesThePluginName: the Codex prompt for flow review is \$flow:review gh#9, because a bare \$review could resolve to the standards plugin's review skill" sh -c "[ \"\$(FLOW_PLUGIN='$P' sh -c '. \"$P/lib/host.sh\"; host_skill_prompt codex flow review gh#9')\" = '\$flow:review gh#9' ]"
check "HostSkillPrompt_CodexSkillOfAnotherPlugin_NamesThatPlugin: the Codex prompt for meta retro is \$meta:retro gh#9 now, because the prompt names the plugin that owns the skill and passes the text untouched" sh -c "[ \"\$(FLOW_PLUGIN='$P' sh -c '. \"$P/lib/host.sh\"; host_skill_prompt codex meta retro \"gh#9 now\"')\" = '\$meta:retro gh#9 now' ]"
check "HostSkillPrompt_ClaudeSkill_KeepsTheSlashPluginForm: the Claude prompt for flow review is /flow:review gh#9, because Claude starts a plugin's skill as /plugin:skill" sh -c "[ \"\$(FLOW_PLUGIN='$P' sh -c '. \"$P/lib/host.sh\"; host_skill_prompt claude flow review gh#9')\" = '/flow:review gh#9' ]"
check "the unattended loop starts a skill step as typed" grep -q 'host_skill_prompt "$host" flow "$skill"' "$P/templates/run-unattended.sh"
# The chase asks the reviewers of the PR's author host: the pr_host of the item its branch names.
cp .flow/config.yaml "$work/config.jobs"; printf 'reviews:\n  reviewers:\n    claude: [codex]\n    codex: [octo-cat]\n  chase_after: 30m\n' >> .flow/config.yaml
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(headRefName='flow/gh-21', isDraft=False); json.dump(d, open(p,'w'))"
"$P/adapters/github/write-state.sh" 'gh#21' pr=https://gh/pull/91 pr_host=claude >/dev/null; seed 7200 running 0; rm -rf .flow/reviews
"$P/jobs/comments.sh" claude >/dev/null
check "comments job: a silent reviewer of the author host's list is chased" sh -c "python3 -c \"import json,sys; c=json.loads(sys.argv[1]); assert len(c)==1 and 'flow:chase codex' in c[0], c\" '$(pr_field comments)'"
"$P/adapters/github/write-state.sh" 'gh#21' pr_host=codex >/dev/null; seed 7200 running 0; rm -rf .flow/reviews
"$P/jobs/comments.sh" claude >/dev/null
check "comments job: a reviewer off the author host's list is not chased" [ "$(posted)" = 0 ]
cp "$work/config.jobs" .flow/config.yaml; "$P/adapters/github/write-state.sh" 'gh#21' pr=https://gh/pull/90 pr_host= >/dev/null
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  model: haiku\n  effort: low\n' > .flow/config.yaml
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "jobs.model and jobs.effort reach the host" sh -c "grep -q 'gh#21.*--model haiku --effort low' '$HOST_LOG'"
check "the old jobs.model and jobs.effort are a fallback, with one deprecation warning naming the new keys" sh -c "[ \"\$(grep -c 'jobs.model and jobs.effort are deprecated: set jobs.claude.model and jobs.claude.effort' .flow/log/comments.log)\" = 1 ]"
jobscfg() { printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n%b' "$1" > .flow/config.yaml; }
deprecated() { grep -c 'jobs.model and jobs.effort are deprecated' .flow/log/comments.log; }
jobscfg '  model: opus\n  effort: high\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" codex 'gh#21' >/dev/null
check "the fallback maps the old model for codex: opus is gpt-6.1-sol" sh -c "grep -q 'exec .*-m gpt-6.1-sol -c model_reasoning_effort=\"high\"' '$HOST_LOG'"
jobscfg '  model: haiku\n  effort: low\n  claude:\n    model: claude-opus-x\n    effort: xhigh\n'; : > "$HOST_LOG"; before="$(deprecated)"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "jobs.claude.model and jobs.claude.effort reach claude as --model and --effort, as is" sh -c "grep -q 'gh#21.*--model claude-opus-x --effort xhigh' '$HOST_LOG'"
check "with jobs.claude set, the old keys are not read and no warning is logged" [ "$(deprecated)" = "$before" ]
jobscfg '  codex:\n    model: opus\n    effort: xhigh\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" codex 'gh#21' >/dev/null
check "jobs.codex.model and jobs.codex.effort reach codex exec as -m and model_reasoning_effort, unmapped" sh -c "grep -q 'exec .*-m opus -c model_reasoning_effort=\"xhigh\"' '$HOST_LOG'"
jobscfg '  model: haiku\n  effort: low\n  claude:\n    model: ""\n    effort: ""\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "an empty jobs.claude pair is the host default: no --model, no --effort, no fallback" sh -c "grep -q 'gh#21' '$HOST_LOG' && ! grep -q -- '--model\|--effort' '$HOST_LOG'"
jobscfg '  codex:\n    effort: max\n'; : > "$HOST_LOG"
"$P/jobs/comments.sh" codex 'gh#21' >/dev/null 2>"$work/job.err"; code=$?
check "an effort codex does not take fails the job early, exit 2, naming the key and its line" sh -c "[ $code = 2 ] && grep -q 'flow: .flow/config.yaml:13: jobs.codex.effort is max; codex takes low, medium, high or xhigh' '$work/job.err' && [ ! -s '$HOST_LOG' ]"
check "a refused effort is a failed run in runs.jsonl, so status shows it" sh -c "tail -1 .flow/log/runs.jsonl | grep -q '\"job\":\"comments\".*\"exit\":2,\"result\":\"error: .flow/config.yaml:13: jobs.codex.effort is max'"
check "a refused effort leaves one line in the job log" [ "$(grep -c 'error: .flow/config.yaml:13: jobs.codex.effort is max' .flow/log/comments.log)" = 1 ]
jobscfg '  claude:\n    effort: max\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1
check "max is a claude effort" grep -q 'gh#21.*--effort max' "$HOST_LOG"
jobscfg '  claude:\n    model: claude-opus-x\n    effort: xhigh\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' --model claude-sched-y --effort low >/dev/null 2>&1
check "a job's --model and --effort win over jobs.<host> for that run, and are taken out of its args" sh -c "grep -q 'gh#21.*--model claude-sched-y --effort low' '$HOST_LOG' && ! grep -q claude-opus-x '$HOST_LOG' && grep -q 'model claude-sched-y, effort low' .flow/log/comments.log"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1
check "a job's --model and --effort hold for their run only: the next run is on jobs.claude again" grep -q 'gh#21.*--model claude-opus-x --effort xhigh' "$HOST_LOG"
: > "$HOST_LOG"; "$P/jobs/comments.sh" codex 'gh#21' --effort max >/dev/null 2>"$work/job.err"; code=$?
check "a job's --effort the host does not take fails the run early, exit 2, as a failed run" sh -c "[ $code = 2 ] && grep -q 'flow: --effort is max; codex takes low, medium, high or xhigh' '$work/job.err' && [ ! -s '$HOST_LOG' ] && tail -1 .flow/log/runs.jsonl | grep -q '\"job\":\"comments\".*\"exit\":2'"
check "a job's --model needs a value, exit 2" sh -c "'$P/jobs/comments.sh' claude --model 2>/dev/null; [ \$? = 2 ]"
jobscfg '  codex:\n    effort: max\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" codex 'gh#21' --effort low >/dev/null 2>&1
check "a job's --effort replaces a jobs.<host>.effort the host does not take, so that run starts" grep -q 'exec .*model_reasoning_effort="low"' "$HOST_LOG"
jobscfg '  host: vim\n'; : > "$HOST_LOG"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>"$work/job.err"; code=$?
check "a jobs.host other than claude or codex fails the job early, exit 2" sh -c "[ $code = 2 ] && grep -q 'jobs.host is vim; it must be claude or codex' '$work/job.err' && [ ! -s '$HOST_LOG' ]"
check "jobs.sh run refuses a bad jobs.host, exit 2" sh -c "'$P/scripts/jobs.sh' run comments 2>&1; [ \$? = 2 ]"
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  model: haiku\n  effort: low\n' > .flow/config.yaml
check "the unattended loop keeps mapping the roster's names for codex" sh -c "FLOW_PLUGIN='$P' sh -c '. \"$P/lib/flow.sh\"; . \"$P/lib/host.sh\"; host_run codex . hi opus high' && grep -q 'exec .*-m gpt-6.1-sol' '$HOST_LOG'"
# Passes at once: jobs.comments_workers or --workers N runs each PR's pass in its own worker.
cp .flow/config.yaml "$work/config.workers"
# The fake gh has one PR: both items link it, and each pass keeps its own seen file by item.
par="$("$P/adapters/github/create.sh" task "A second PR")"
"$P/adapters/github/write-state.sh" "$par" step=pr >/dev/null && "$P/adapters/github/link-pr.sh" "$par" https://gh/pull/90 >/dev/null
# The host waits up to 10 s for a second pass to start, so passes at once both start before either ends.
cat > "$work/bin/claude" <<EOF
#!/bin/sh
printf 'start %s\n' "\$*" >> "$work/overlap.log"
i=0; while [ "\$(grep -c '^start' "$work/overlap.log")" -lt 2 ] && [ "\$i" -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done
printf 'end %s\n' "\$*" >> "$work/overlap.log"
EOF
cp "$work/bin/claude" "$work/overlap-host"
jobscfg '  comments_workers: 2\n'; bump 2026-10-25T03:00:00Z; : > "$work/overlap.log"
"$P/jobs/comments.sh" claude >/dev/null 2>&1; code=$?
check_all "comments job: jobs.comments_workers 2 starts both PRs' passes before either ends, because each worker takes its own PR" '[ "$code" -eq 0 ] && [ "$(head -n 2 "$work/overlap.log" | grep -c "^start")" = 2 ] && grep -q "^start .*comments gh#21\." "$work/overlap.log" && grep -q "^start .*comments $par\." "$work/overlap.log"'
check_all "comments job: the result line counts and names the passes of every worker" 'tail -1 .flow/log/comments.log | grep -q "done: 2 PR(s) addressed: [^;]*\$" && tail -1 .flow/log/comments.log | grep -q "gh#21" && tail -1 .flow/log/comments.log | grep -q "$par" && grep "\"job\":\"comments\"" .flow/log/runs.jsonl | tail -1 | grep -q "\"result\":\"done: 2 PR(s) addressed: "' 
check "comments job: each pass lets its item's lock go, and the run's files go with it" sh -c "! ls -d .flow/item:*.lock >/dev/null 2>&1 && ! ls .flow/log/comments.out.* >/dev/null 2>&1"
printf "$okhost" > "$work/bin/claude"; jobscfg ''; : > "$HOST_LOG"
"$P/jobs/comments.sh" claude --workers 2 >/dev/null 2>&1
check_all "comments job: --workers 2 with nothing new sums and names the unchanged PRs, because each worker's pass is counted" '[ ! -s "$HOST_LOG" ] && tail -1 .flow/log/comments.log | grep -q "quiet: nothing new on 2 PR(s): [^;]*\$" && tail -1 .flow/log/comments.log | grep -q "$par"' 
# A pass whose item's lock another holds skips that PR, as in use; the other worker's pass runs.
mkdir ".flow/item:$(item_slug "$par").lock" && echo $$ > ".flow/item:$(item_slug "$par").lock/pid"
bump 2026-10-25T03:10:00Z; : > "$HOST_LOG"
"$P/jobs/comments.sh" claude --workers 2 >/dev/null 2>&1; code=$?
check_all "comments job: a held item lock skips that PR's pass, because no two passes work one item at once" '[ "$code" -eq 0 ] && ! grep -q "comments $par\." "$HOST_LOG" && grep -q "comments gh#21\." "$HOST_LOG" && grep -q "$par: another pass works on $par (its lock is held), skipped" .flow/log/comments.log'
check_all "comments job: a PR skipped for its held lock is named in use in the result line" 'tail -1 .flow/log/comments.log | grep -q "done: 1 PR(s) addressed: gh#21; 1 in use: $par (another pass holds its lock)\$"' 
check "comments job: a lock the run did not take is left to its holder" [ -d ".flow/item:$(item_slug "$par").lock" ]
rm -rf ".flow/item:$(item_slug "$par").lock"
check "comments job: --workers 0 is refused, exit 2" sh -c "'$P/jobs/comments.sh' claude --workers 0 2>/dev/null; [ \$? = 2 ]"
mark_comments_log; "$P/jobs/comments.sh" claude --workers 00 >/dev/null 2>&1; code=$?
check "WorkersOfZerosOnly_RefusesTheRun: 00 workers would leave every pass waiting for a slot, exit 2" [ "$code" -eq 2 ]
check_all "WorkersOfZerosOnly_StartsNoPass: no pass is addressed on a zero worker count" '! comments_logged_since_mark "addressing "'
WORKERS_CAP="$(sed -n 's/^COMMENTS_WORKERS_MAX=//p' "$P/jobs/comments.sh")"
WORKERS_PAST_ANY_SHELL_INTEGER=99999999999999999999
REFUSED_RUN_BOUND_SECONDS=15; REFUSED_RUN_STOP_GRACE_SECONDS=1
bounded_comments_run() { python3 -I "$P/scripts/_health.py" bounded "$REFUSED_RUN_BOUND_SECONDS" "$REFUSED_RUN_STOP_GRACE_SECONDS" "$P/jobs/comments.sh" claude "$@" >/dev/null 2>&1; }
bump 2026-10-25T03:05:00Z; mark_comments_log; bounded_comments_run --workers "$((WORKERS_CAP + 1))"; code=$?
check "WorkersAboveTheCap_RefusesTheRun: --workers takes no more passes at once than jobs.comments_workers may, exit 2" [ "$code" -eq 2 ]
check_all "WorkersAboveTheCap_StartsNoPass: no pass is addressed on a refused worker count" '! comments_logged_since_mark "addressing "'
bump 2026-10-25T03:06:00Z; mark_comments_log; bounded_comments_run --workers "$WORKERS_PAST_ANY_SHELL_INTEGER"; code=$?
check "WorkersPastAnyShellInteger_RefusesTheRun: a count too big to compare would leave every pass waiting for a slot, exit 2" [ "$code" -eq 2 ]
check_all "WorkersPastAnyShellInteger_StartsNoPass: no pass is addressed on a refused worker count" '! comments_logged_since_mark "addressing "'
jobscfg "  comments_workers: $((WORKERS_CAP + 1))\n"; bump 2026-10-25T03:07:00Z; mark_comments_log; bounded_comments_run; code=$?
check "ConfiguredWorkersAboveTheCap_RefusesTheRun: jobs.comments_workers past the console's range stops the run at its start, exit 2" [ "$code" -eq 2 ]
check_all "ConfiguredWorkersAboveTheCap_StartsNoPass: no pass is addressed on a refused worker count" '! comments_logged_since_mark "addressing "'
jobscfg "  comments_workers: $WORKERS_PAST_ANY_SHELL_INTEGER\n"; bump 2026-10-25T03:08:00Z; mark_comments_log; bounded_comments_run; code=$?
check "ConfiguredWorkersPastAnyShellInteger_RefusesTheRun: a count too big to compare would leave every pass waiting for a slot, exit 2" [ "$code" -eq 2 ]
check_all "ConfiguredWorkersPastAnyShellInteger_StartsNoPass: no pass is addressed on a refused worker count" '! comments_logged_since_mark "addressing "'
jobscfg ''; bump 2026-10-25T03:09:00Z; mark_comments_log; bounded_comments_run --workers "$WORKERS_CAP"
check "WorkersAtTheCap_AddressesThePrs: the console's top worker count still runs the passes" comments_logged_since_mark 'done: .*addressed: .*gh#21'
cp "$work/overlap-host" "$work/bin/claude"
jobscfg '  comments_workers: 02\n'; bump 2026-10-25T03:15:00Z; : > "$work/overlap.log"
"$P/jobs/comments.sh" claude >/dev/null 2>&1
check "ConfiguredWorkersWithALeadingZero_RunsThatManyPassesAtOnce: 02 starts both PRs' passes before either ends" [ "$(head -n 2 "$work/overlap.log" | grep -c '^start')" = 2 ]
printf "$okhost" > "$work/bin/claude"; jobscfg ''
# A pass the host stops ends its own worker; the pass already running in the other one finishes.
cat > "$work/bin/claude" <<EOF
#!/bin/sh
printf 'start %s\n' "\$*" >> "$work/overlap.log"
i=0; while [ "\$(grep -c '^start' "$work/overlap.log")" -lt 2 ] && [ "\$i" -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done
case "\$*" in
  *"comments gh#21."*) FLOW_HOST_GATES=1 sh -c '. "\$FLOW_PLUGIN/lib/flow.sh"; . "\$FLOW_PLUGIN/lib/host.sh"; host_stop claude spend-limit "API Error: 422 ExceededBudget"'
    printf 'end %s\n' "\$*" >> "$work/overlap.log"; exit 1 ;;
esac
i=0; while ! grep -q '^end .*comments gh#21\.' "$work/overlap.log" && [ "\$i" -lt 100 ]; do sleep 0.1; i=\$((i + 1)); done
printf 'end %s\n' "\$*" >> "$work/overlap.log"
EOF
bump 2026-10-25T03:20:00Z; : > "$work/overlap.log"
"$P/jobs/comments.sh" claude --workers 2 >/dev/null 2>&1; code=$?
check_all "comments job: a pass the host stopped ends only its worker, because the other pass in flight finishes" '[ "$code" -eq 0 ] && tail -n 1 "$work/overlap.log" | grep -q "^end .*comments $par\." && ! grep -q "$par: pass failed" .flow/log/comments.log'
check "comments job: with no pass failed, the host's stop is the run's last word" sh -c "grep '\"job\":\"comments\"' .flow/log/runs.jsonl | tail -1 | grep -q '\"exit\":0,\"result\":\"stopped: claude is stopped since '"
"$P/scripts/gate.sh" clear claude >/dev/null
printf "$okhost" > "$work/bin/claude"; : > "$HOST_LOG"
"$P/jobs/comments.sh" claude --workers 2 >/dev/null 2>&1
check_all "comments job: after the clear only the stopped pass's PR runs again, because the finished pass kept its activity" 'grep -q "comments gh#21\." "$HOST_LOG" && ! grep -q "comments $par\." "$HOST_LOG"'
# A failed pass beside one that completes: the run exits 1 and names the failed PR.
printf '#!/bin/sh\ncase "$*" in *"comments gh#21."*) exit 1 ;; esac\n' > "$work/bin/claude"
bump 2026-10-25T03:30:00Z
"$P/jobs/comments.sh" claude --workers 2 >/dev/null 2>&1; code=$?
check "comments job: one failed pass among workers fails the run, exit 1, the line summing both" sh -c "[ $code -eq 1 ] && tail -1 .flow/log/comments.log | grep -q 'failed: gh#21 cut short or failed, of 2 PR(s) addressed\$'"
# A pass by hand that completes clears the failure and the resume note it left on gh#21.
printf "$okhost" > "$work/bin/claude"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1
"$P/adapters/github/write-state.sh" "$par" pr= >/dev/null; "$P/adapters/github/close.sh" "$par" >/dev/null 2>&1
bump 2026-10-25T04:00:00Z
"$P/jobs/comments.sh" claude --as comments-fast >/dev/null 2>&1
mark_comments_log; "$P/jobs/comments.sh" claude >/dev/null 2>&1
check_all "SecondScheduleAddressedThePr_PlainRunFindsNothingNew: every schedule of the job shares one seen record per PR" \
  'comments_logged_since_mark "gh#21: nothing new since the last pass, skipped" && ! comments_logged_since_mark "addressing gh#21"'
bump 2026-10-25T04:10:00Z; rm -f .flow/log/comments.seen/gh_21
answered_before="$("$P/adapters/github/read.sh" 'gh#21' | jget state.answered_at 2>/dev/null)"
"$P/adapters/github/write-state.sh" 'gh#21' answered_at=2026-10-25T04:05:00Z >/dev/null
"$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "PrNamedByNumberOfAnItem_WritesTheItemsSeenRecord: the PR's number and its item are one key" test -s .flow/log/comments.seen/gh_21
mark_comments_log; "$P/jobs/comments.sh" claude >/dev/null 2>&1
check_all "PrNamedByNumberOfAnItem_LeavesNothingNewForTheItemsNextRun: a pass named by the PR's number keeps the item's activity" \
  'comments_logged_since_mark "gh#21: nothing new since the last pass, skipped" && ! comments_logged_since_mark "addressing gh#21"'
"$P/adapters/github/write-state.sh" 'gh#21' "answered_at=$answered_before" >/dev/null
printf 'another run lists these\n' > .flow/log/comments.targets; cp .flow/log/comments.targets .flow/log/comments.gated
"$P/adapters/github/write-state.sh" 'gh#21' gate=ambiguity >/dev/null
"$P/jobs/comments.sh" claude >/dev/null 2>&1
"$P/adapters/github/write-state.sh" 'gh#21' gate=none >/dev/null
check "OverlappingRunsTargetList_IsNotWrittenByAnotherRun: each run lists its targets in a file of its own" grep -qx 'another run lists these' .flow/log/comments.targets
check "OverlappingRunsGatedList_IsNotWrittenByAnotherRun: each run lists its gated items in a file of its own" grep -qx 'another run lists these' .flow/log/comments.gated
rm -f .flow/log/comments.targets .flow/log/comments.gated
flow_home_dir="$PWD/.flow"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['headRefName']='feature/by-hand'; json.dump(d, open(p,'w'))"
cat > "$work/bin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "\$HOST_LOG"
[ -d "$flow_home_dir/pr:90.lock" ] && echo held > "$work/pr-lock.during"
EOF
chmod +x "$work/bin/claude"; rm -f "$work/pr-lock.during"
"$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "HandNamedPrWithNoItem_HoldsALockKeyedByItsNumberDuringThePass: no two passes work one PR at once" test -f "$work/pr-lock.during"
check "HandNamedPrWithNoItem_LetsItsLockGoAfterThePass: the next pass on the PR can start" test ! -d .flow/pr:90.lock
mkdir .flow/pr:90.lock && echo $$ > .flow/pr:90.lock/pid
mark_comments_log; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check_all "HandNamedPrWhoseLockIsHeld_IsSkipped: another pass works on that PR" \
  'comments_logged_since_mark "90: another pass works on it (its lock is held), skipped" && ! comments_logged_since_mark "addressing 90"'
check "HandNamedPrWhoseLockIsHeld_IsNamedInUse: the result line says why the PR was not addressed" sh -c "tail -1 .flow/log/comments.log | grep -q 'in use: 90 '"
rm -rf .flow/pr:90.lock
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['headRefName']='flow/gh-21'; json.dump(d, open(p,'w'))"
cap="$("$P/adapters/github/create.sh" task "A PR for the second run")"
"$P/adapters/github/write-state.sh" "$cap" step=pr >/dev/null && "$P/adapters/github/link-pr.sh" "$cap" https://gh/pull/90 >/dev/null
cat > "$work/bin/claude" <<EOF
#!/bin/sh
printf 'start %s\n' "\$*" >> "$work/runs.log"
case "\$*" in *"comments gh#21."*) poll_count=0; while [ ! -f "$work/release" ] && [ "\$poll_count" -lt $POLL_LIMIT ]; do sleep 0.1; poll_count=\$((poll_count + 1)); done ;; esac
printf 'end %s\n' "\$*" >> "$work/runs.log"
EOF
chmod +x "$work/bin/claude"
jobscfg '  comments_workers: 2\n'; bump 2026-10-25T04:20:00Z; rm -f "$work/release"; : > "$work/runs.log"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1 & first_run=$!
wait_for grep -q '^start .*comments gh#21\.' "$work/runs.log"
"$P/jobs/comments.sh" claude >/dev/null 2>&1
second_alive_at_end=no; kill -0 "$first_run" 2>/dev/null && second_alive_at_end=yes
touch "$work/release"; wait "$first_run"
check "SecondRunWhileOneIsAlive_AddressesTheFreePr: runs of the comments job overlap" sh -c "[ $second_alive_at_end = yes ] && grep -q '^end .*comments $cap\.' '$work/runs.log'"
check "SecondRunWhileOneIsAlive_SkipsOnlyThePrWhoseLockIsHeld: the live run's PR is not addressed twice" [ "$(grep -c '^start .*comments gh#21\.' "$work/runs.log")" = 1 ]
jobscfg '  comments_workers: 1\n'; rm -f "$work/release"; : > "$work/runs.log"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1 & first_run=$!
wait_for grep -q '^start .*comments gh#21\.' "$work/runs.log"
"$P/jobs/comments.sh" claude "$cap" >/dev/null 2>&1 & second_run=$!
wait_for grep -q "$cap: waits for a free pass slot" .flow/log/comments.log
touch "$work/release"; wait "$first_run"; wait "$second_run"
check "TwoRunsWithOneWorkerConfigured_NeverOverlapTheirPasses: live passes across runs stay within jobs.comments_workers" \
  [ "$(sed 's/ .*comments \([^ ]*\)\..*/ \1/' "$work/runs.log" | tr '\n' '|')" = "start gh#21|end gh#21|start $cap|end $cap|" ]
rm -f "$work/release"; : > "$work/runs.log"; mkdir -p .flow/log/comments.slots && ln -sfn 999999 .flow/log/comments.slots/1
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1 & first_run=$!
"$P/jobs/comments.sh" claude "$cap" >/dev/null 2>&1 & second_run=$!
wait_for grep -q '^start .*comments gh#21\.' "$work/runs.log"
slot_holder="$(readlink .flow/log/comments.slots/1)"
touch "$work/release"; wait "$first_run"; wait "$second_run"
check "StaleSlotTakenByTwoRunsAtOnce_NeverOverlapsTheirPasses: a slot a dead run left is taken by one run only" \
  awk '/^start /{live++; if (live > 1) overlap=1} /^end /{live--} END{exit overlap}' "$work/runs.log"
check "StaleSlotTakenByTwoRunsAtOnce_AddressesBothPrs: the run that lost the slot waits for it instead of skipping" \
  sh -c "grep -q '^end .*comments gh#21\.' '$work/runs.log' && grep -q '^end .*comments $cap\.' '$work/runs.log'"
check "SlotHeldByALivePass_NamesItsRunsPid: a slot is never held with no pid" [ "$slot_holder" = "$first_run" ]
mkdir -p .flow/log/comments.slots && ln -sfn 999999 .flow/log/comments.slots/1
printf "$okhost" > "$work/bin/claude"; : > "$HOST_LOG"; mark_comments_log
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1 & stale_run=$!
wait_for grep -q 'comments gh#21' "$HOST_LOG"
kill "$stale_run" 2>/dev/null; wait "$stale_run" 2>/dev/null
check "SlotOfADeadRun_IsTakenOver: a run that died holds no pass slot" comments_logged_since_mark 'addressing gh#21'
ln -sfn 999999 .flow/log/comments.slots/1 && ln -sfn 999998 .flow/log/comments.slots/1.999999; : > "$HOST_LOG"; mark_comments_log
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1 & guarded_run=$!
wait_for grep -q 'comments gh#21' "$HOST_LOG"
kill "$guarded_run" 2>/dev/null; wait "$guarded_run" 2>/dev/null; rm -f .flow/log/comments.slots/1.999999
check "TakeoverGuardOfADeadRun_IsCleared: a takeover stopped halfway never keeps its slot from being taken back" comments_logged_since_mark 'addressing gh#21'
# The path names jobs/comments.sh because the job's liveness check matches that in a command line.
GUARD_HOLD_SECONDS=2
"$work/fake/jobs/comments.sh" >/dev/null 2>&1 & live_taker=$!
bump 2026-10-25T04:30:00Z; ln -sfn 999999 .flow/log/comments.slots/1 && ln -sfn "$live_taker" .flow/log/comments.slots/1.999999; : > "$HOST_LOG"
mark_comments_log
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1 & guarded_run=$!
wait_for comments_logged_since_mark 'gh#21: waits for a free pass slot'
guarded_run_waited=no; ! comments_logged_since_mark 'gh#21: waits for a free pass slot' || guarded_run_waited=yes
sleep "$GUARD_HOLD_SECONDS"; guarded_pass_started=no; ! comments_logged_since_mark 'addressing gh#21' || guarded_pass_started=yes
kill "$live_taker" 2>/dev/null; wait "$live_taker" 2>/dev/null
wait_for grep -q 'comments gh#21' "$HOST_LOG"
kill "$guarded_run" 2>/dev/null; wait "$guarded_run" 2>/dev/null; rm -f .flow/log/comments.slots/1.999999
check_all "TakeoverGuardOfALiveRun_HoldsTheSlotWhileItsTakerLives: a live takeover is never raced by a second taker" \
  '[ "$guarded_run_waited" = yes ] && [ "$guarded_pass_started" = no ]'
check "TakeoverGuardOfALiveRun_FreesTheSlotOnceItsTakerEnds: the waiting pass runs when the taker is gone" comments_logged_since_mark 'addressing gh#21'
stale_pool="$work/stale-guard-pool"; mkdir -p "$stale_pool/slots"
ln -s 999999 "$stale_pool/slots/1" && ln -s 999998 "$stale_pool/slots/1.999999"
for taker in 11 12 13 14 15 16 17 18; do
  ( job_alive() { case "$1" in 99999*) return 1 ;; esac; return 0; }; . "$P/lib/slots.sh"
    poll_count=0; while [ ! -e "$stale_pool/start" ] && [ "$poll_count" -lt "$POLL_LIMIT" ]; do sleep 0.1; poll_count=$((poll_count + 1)); done
    slot_try "$stale_pool/slots" 1 "$taker" >/dev/null && echo "$taker" >> "$stale_pool/winners" ) &
  taker_runs="${taker_runs:-} $!"
done
touch "$stale_pool/start"; for taker_run in $taker_runs; do wait "$taker_run"; done
check_all "SlotAndTakeoverGuardBothStale_AreTakenByOneTakerOnly: two takers of a dead taker's guard never both hold the slot" \
  '[ "$(wc -l < "$stale_pool/winners" | tr -d " ")" = 1 ] && [ "$(readlink "$stale_pool/slots/1")" = "$(cat "$stale_pool/winners")" ]'
check_all "SlotAndTakeoverGuardBothStale_LeaveNoGuardOnceTaken: a recovered takeover guard is never left behind" \
  '[ "$(ls "$stale_pool/slots" | tr "\n" " ")" = "1 " ]'
STUBBORN_HOST_SECONDS=30
cat > "$work/bin/claude" <<EOF
#!/bin/sh
case "\$*" in *"comments gh#21."*) trap '' TERM; echo \$\$ > "$work/stubborn-host.pid"; printf 'start gh#21\n' >> "$work/runs.log"; sleep $STUBBORN_HOST_SECONDS; exit 0 ;; esac
if kill -0 "\$(cat "$work/stubborn-host.pid")" 2>/dev/null; then stubborn=alive; else stubborn=gone; fi
printf 'start %s beside a stubborn host %s\n' "\$*" "\$stubborn" >> "$work/runs.log"
EOF
chmod +x "$work/bin/claude"; : > "$work/runs.log"; rm -f "$work/stubborn-host.pid"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1 & stopped_run=$!
wait_for grep -q '^start gh#21' "$work/runs.log"
"$P/scripts/jobs.sh" stop comments >/dev/null 2>&1; wait "$stopped_run" 2>/dev/null
"$P/jobs/comments.sh" claude "$cap" >/dev/null 2>&1
check "StoppedRunWhoseHostIgnoresTerm_KeepsItsSlotUntilTheHostGroupIsGone: a new run's pass never starts beside the stopped host, because live passes stay within jobs.comments_workers" \
  grep -q "^start .*comments $cap\..* beside a stubborn host gone\$" "$work/runs.log"
"$P/adapters/github/write-state.sh" "$cap" pr= >/dev/null; "$P/adapters/github/close.sh" "$cap" >/dev/null 2>&1
HELPER_HOLD_SECONDS=30
cat > "$work/bin/claude" <<EOF
#!/bin/sh
sleep $HELPER_HOLD_SECONDS </dev/null >/dev/null 2>&1 &
echo \$! > "$work/helper.pid"
EOF
chmod +x "$work/bin/claude"; rm -f "$work/helper.pid"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1
check "HostThatExitsLeavingAHelper_StopsTheHelperBeforeItsSlotIsFreed: a helper left in the host's group never outlives its pass" \
  sh -c ". '$P/lib/process.sh'; test -s '$work/helper.pid' && ! process_running \$(cat '$work/helper.pid')"
if ! ( . "$P/lib/process.sh"; ps_refused ); then
  zombie_pool="$work/zombie-pool"; mkdir -p "$zombie_pool"
  python3 -I -c 'import subprocess, sys, time
ended = subprocess.Popen(["true"], start_new_session=True)
open(sys.argv[1], "w").write("%d\n" % ended.pid)
time.sleep(int(sys.argv[2]))' "$zombie_pool/slot.group" "$HELPER_HOLD_SECONDS" & zombie_keeper=$!
  zombie_group_ended() { read -r zombie_group < "$zombie_pool/slot.group" && case "$(ps -o stat= -p "$zombie_group")" in Z*) ;; *) false ;; esac; }
  zombie_slot_is_free() { zombie_group_ended && ( . "$P/lib/process.sh"; . "$P/lib/slots.sh"; ! slot_group_alive "$zombie_pool/slot" ); }
  wait_for zombie_group_ended
  check "SlotGroupOfZombiesOnly_IsNotAlive: a group with no running process no longer holds its slot" zombie_slot_is_free
  kill "$zombie_keeper" 2>/dev/null; wait "$zombie_keeper" 2>/dev/null
fi
PASS_LIMIT_BOUND_SECONDS=15
cat > "$work/bin/claude" <<EOF
#!/bin/sh
sleep 30 & echo \$! > "$work/pass-child.pid"
wait
EOF
chmod +x "$work/bin/claude"; rm -f .flow/log/comments.seen/gh_21.fails "$work/pass-child.pid"
jobscfg '  comments:\n    pass_limit: 2s\n'
started="$(date +%s)"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1; code=$?; elapsed=$(( $(date +%s) - started ))
check "PassPastThePassLimit_IsStopped: no pass runs forever" [ "$elapsed" -lt "$PASS_LIMIT_BOUND_SECONDS" ]
check "PassPastThePassLimit_FailsTheRun: a stopped pass is a failed pass" [ "$code" -eq 1 ]
check "PassPastThePassLimit_StopsTheHostsChildren: nothing the pass started keeps running" sh -c "test -s '$work/pass-child.pid' && ! kill -0 \$(cat '$work/pass-child.pid')"
check "PassPastThePassLimit_CountsTowardFailuresInARow: it counts toward jobs.comments.max_failures" sh -c "read -r count _ < .flow/log/comments.seen/gh_21.fails && [ \"\$count\" = 1 ]"
check "PassPastThePassLimit_IsLoggedAsStoppedAtTheLimit: the log names the setting that stopped it" grep -q 'gh#21: pass failed, .*jobs.comments.pass_limit' .flow/log/comments.log
printf "$okhost" > "$work/bin/claude"; mark_comments_log; "$P/jobs/comments.sh" claude >/dev/null 2>&1
check "PassStoppedAtThePassLimit_IsTriedAgainByTheNextRun: a stopped pass is retried with nothing new" comments_logged_since_mark 'done: .*addressed: .*gh#21'
jobscfg '  comments:\n    pass_limit: soon\n'; mark_comments_log
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1; code=$?
check "PassLimitThatIsNoDuration_RefusesTheRun: a bad setting fails at startup, exit 2" [ "$code" -eq 2 ]
check_all "PassLimitThatIsNoDuration_StartsNoPass: no pass is addressed on a bad setting" '! comments_logged_since_mark "addressing "'
jobscfg '  comments:\n    pass_limit: 0m\n'; mark_comments_log
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1; code=$?
check "PassLimitOfZero_RefusesTheRun: a limit that would stop every pass at once fails at startup, exit 2" [ "$code" -eq 2 ]
check_all "PassLimitOfZero_StartsNoPass: no pass is addressed on a zero limit" '! comments_logged_since_mark "addressing "'
cp "$work/config.workers" .flow/config.yaml
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['state']='MERGED'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"
"$P/jobs/comments.sh" claude >/dev/null
check "comments job: merged PR skipped, quiet" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'quiet: no open PR' .flow/log/comments.log"
# The paths name jobs/<job>.sh because the job's liveness check matches that in a command line.
printf '#!/bin/sh\nsleep 60 &\nwait\n' > "$work/fake/jobs/intake.sh" && chmod +x "$work/fake/jobs/intake.sh"
fakeintake="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/intake.sh")"
mkdir -p .flow/log/intake.lock && echo "$fakeintake" > .flow/log/intake.lock/pid
check "IntakeRunBesideALiveRunOfItsSchedule_Skips: an intake schedule runs one at a time" sh -c "'$P/jobs/intake.sh' claude | grep -q 'skipped: run $fakeintake still going'"
check "JobLockWhereNoPsRuns_LivePidSkips: pgrep sees the run, so a live lock is never taken for a stale one" \
  sh -c "PATH='$refused_ps':\$PATH '$P/jobs/intake.sh' claude | grep -q 'skipped: run $fakeintake still going'"
mkdir -p .flow/log/intake.shared.lock && echo "$fakeintake" > .flow/log/intake.shared.lock/pid && printf intake > .flow/log/intake.shared.lock/name
"$P/jobs/intake.sh" claude --as intake-nightly > "$work/shared.out" 2>&1
check "IntakeScheduleBesideAHeldSharedLock_Skips: the schedules of intake share its state, so they take turns" grep -q "skipped: intake is running (pid $fakeintake), which shares the intake job.s state" "$work/shared.out"
check "IntakeScheduleBesideAHeldSharedLock_RemovesItsOwnLock: a skipped run leaves no lock behind" test ! -d .flow/log/intake-nightly.lock
check "IntakeScheduleBesideAHeldSharedLock_LeavesTheSharedLockToItsHolder: the live holder keeps its turn" sh -c "[ \"\$(cat .flow/log/intake.shared.lock/pid)\" = $fakeintake ]"
rm -rf .flow/log/intake.shared.lock .flow/log/intake.lock
pkill -P "$fakeintake" 2>/dev/null; kill "$fakeintake" 2>/dev/null
printf '#!/bin/sh\nsleep 60 &\nwait\n' > "$work/fake/jobs/retro.sh" && chmod +x "$work/fake/jobs/retro.sh"
fakeretro="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/retro.sh")"
mkdir -p .flow/log/retro.shared.lock && echo "$fakeretro" > .flow/log/retro.shared.lock/pid && printf retro > .flow/log/retro.shared.lock/name
"$P/jobs/retro.sh" claude --as retro-weekly > "$work/shared.out" 2>&1
check "RetroScheduleBesideAHeldSharedLock_Skips: the schedules of retro share its state, so they take turns" grep -q "skipped: retro is running (pid $fakeretro), which shares the retro job.s state" "$work/shared.out"
rm -rf .flow/log/retro.shared.lock
pkill -P "$fakeretro" 2>/dev/null; kill "$fakeretro" 2>/dev/null
fakejob="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/comments.sh")"
mkdir -p ".flow/log/comments-$fakejob.lock" && echo "$fakejob" > ".flow/log/comments-$fakejob.lock/pid"
"$P/jobs/comments.sh" claude > "$work/beside.out" 2>&1
check "CommentsRunBesideALiveRun_Starts: runs of the comments job overlap" grep -q 'quiet: no open PR' "$work/beside.out"
check "CommentsRunBesideALiveRun_LeavesOnlyTheLiveRunsLock: a run removes its own lock and never a live one" \
  sh -c "[ \"\$(ls -d .flow/log/comments-[0-9]*.lock)\" = '.flow/log/comments-$fakejob.lock' ]"
check "JobLockWhereNoPsRuns_KeepsALiveRunsLock: pgrep sees the run, so a live lock is never taken for a stale one" \
  sh -c "PATH='$refused_ps':\$PATH '$P/jobs/comments.sh' claude >/dev/null 2>&1; [ -d '.flow/log/comments-$fakejob.lock' ]"
mkdir -p .flow/log/comments.shared.lock && echo "$fakejob" > .flow/log/comments.shared.lock/pid && printf comments > .flow/log/comments.shared.lock/name
"$P/jobs/comments.sh" claude --as comments-fast > "$work/beside.out" 2>&1
check "CommentsScheduleBesideAHeldSharedLock_Starts: the comments job takes no shared lock" grep -q 'quiet: no open PR' "$work/beside.out"
check "CommentsScheduleBesideAHeldSharedLock_LeavesItToItsHolder: a comments run never takes over the shared lock" \
  sh -c "[ \"\$(cat .flow/log/comments.shared.lock/pid)\" = $fakejob ]"
rm -rf .flow/log/comments.shared.lock ".flow/log/comments-$fakejob.lock"
pkill -P "$fakejob" 2>/dev/null; kill "$fakejob" 2>/dev/null
mkdir -p .flow/log/comments-999999.lock && echo 999999 > .flow/log/comments-999999.lock/pid
"$P/jobs/comments.sh" claude > "$work/stale.out" 2>&1
check "CommentsRunBesideAStaleLock_Starts: a lock whose pid is gone holds nothing" grep -q 'quiet: no open PR' "$work/stale.out"
check "StaleCommentsRunLock_IsRemovedByTheNextRun: the next run clears a lock whose pid is gone" test ! -d .flow/log/comments-999999.lock
sleep 60 & other=$!
mkdir -p ".flow/log/comments-$other.lock" && echo "$other" > ".flow/log/comments-$other.lock/pid"
"$P/jobs/comments.sh" claude >/dev/null 2>&1
check "CommentsRunLockOfAPidARestartGaveAway_IsRemoved: a pid that runs something else is stale" test ! -d ".flow/log/comments-$other.lock"
check "CommentsRunLockOfAPidARestartGaveAway_LeavesThatProcessAlone: only the lock goes" kill -0 "$other"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
check "job: unknown host refused" sh -c "! '$P/jobs/comments.sh' vim 2>/dev/null"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  claude:\n    effort: bogus\n' > "$home2/config.yaml"
check "next job: a bad jobs.claude.effort stops it before it picks: its steps with no agent run on the pair" sh -c "FLOW_HOME='$home2' '$P/jobs/next.sh' claude | grep -q 'stopped: exit 2' && grep -q 'jobs.claude.effort is bogus' '$home2/log/next.log'"
check "next job: a bad jobs.claude.effort is named in the run's status line" sh -c "grep '\"job\":\"next\"' '$home2/log/runs.jsonl' | tail -1 | grep -q 'jobs.claude.effort is bogus'"
check "health job: a bad jobs.claude.effort does not stop it either" sh -c "FLOW_HOME='$home2' '$P/jobs/health.sh' claude --dry-run >/dev/null 2>&1; [ \$? != 2 ] && tail -1 '$home2/log/runs.jsonl' | grep -q '\"job\":\"health\"' && ! tail -1 '$home2/log/runs.jsonl' | grep -q '\"exit\":2'"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  host: vim\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$P/jobs/next.sh" claude >/dev/null 2>"$work/job.err"; code=$?
check "next job: a bad jobs.host stops every job, exit 2" sh -c "[ $code = 2 ] && grep -q 'jobs.host is vim' '$work/job.err'"
rm -rf "$home2/log"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' > "$home2/config.yaml"
check "next job: nothing ready is quiet" sh -c "FLOW_HOME='$home2' '$P/jobs/next.sh' claude | grep -q 'quiet: nothing ready'"
check "next job: no idle notification unless notify.idle is on" sh -c "! grep -q '	idle	' '$home2/events.log' 2>/dev/null"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n  idle: true\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$P/jobs/next.sh" claude >/dev/null; FLOW_HOME="$home2" "$P/jobs/next.sh" claude >/dev/null
check "next job: notify.idle says it once, not on every run" [ "$(grep -c '	idle	' "$home2/events.log")" = 1 ]
check "the idle notice is an event, not a gate" sh -c "[ -z \"\$(ls '$home2/gates' 2>/dev/null)\" ]"
check "retro job: no lessons is quiet" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q 'quiet: 0 new'"
FLOW_HOME="$home2" "$P/scripts/lesson.sh" review-blocker 'local:task/9' "Magic number" --rule N-06 >/dev/null
FLOW_HOME="$home2" "$P/scripts/lesson.sh" escalation 'local:task/9' "verify failed 3 times" >/dev/null
: > "$HOST_LOG"
check "retro job: new lessons run the skill" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q 'running over 2 new' && grep -q '/meta:retro Unattended.*Read the 2 lessons.*2 lines; the new ones are those with a time after the start' '$HOST_LOG'"
printf '%s\t2\t1\t1\n' "$(date -u +%FT%TZ)" > "$home2/retros.log"
check "retro job: retros.log marks the lessons read" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude --min-lessons 1 | grep -q 'quiet: 0 new'"
printf '2000-01-01T00:00:00Z\t5\t1\t1\n' > "$home2/retros.log"
check "retro job: a rewritten log shorter than the lines read still runs over the lessons newer than the last retro" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q 'running over 2 new'"
printf '%s\t2\t1\t1\n' "$(date -u +%FT%TZ)" > "$home2/retros.log"
# A clone of an origin with .flow/ excluded, as init leaves it, and one new lesson to read.
mkdir -p "$work/lessons" && git init -q --bare "$work/lessons/origin.git" && git clone -q "$work/lessons/origin.git" "$work/lessons/app" 2>/dev/null
(cd "$work/lessons/app" && git config user.email t@t && git config user.name t && printf '.flow/\n' >> .git/info/exclude &&
  mkdir -p .flow && printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\n' > .flow/config.yaml &&
  git commit -q --allow-empty -m init && git branch -q -M main && git push -q origin main 2>/dev/null &&
  "$P/scripts/lesson.sh" review-blocker 'local:task/9' "Magic number" --rule N-06 >/dev/null && "$P/jobs/retro.sh" claude) > "$work/lessons.out" 2>&1
check "retro job: a run leaves git untouched: nothing staged or committed, the origin's commit count unchanged" sh -c "grep -q 'running over 1 new' '$work/lessons.out' && ! grep -q -e 'lessons log' -e 'left out' '$work/lessons.out' && [ -z \"\$(git -C '$work/lessons/app' status --porcelain)\" ] && [ \"\$(git -C '$work/lessons/app' rev-list --count HEAD)\" = 1 ] && [ \"\$(git -C '$work/lessons/origin.git' rev-list --count main)\" = 1 ]"

echo "flow jobs: the run ledger, pause and the schedule (fake launchctl)"
J="$P/scripts/jobs.sh"
check "a run is a line in runs.jsonl: job, start, length, exit, last words" sh -c "grep '\"job\":\"comments\"' .flow/log/runs.jsonl | grep -q '\"exit\":0,\"result\":\"quiet: no open PR\"'"
check "a run skipped by a live lock is a line too" grep -q '"result":"skipped: run' .flow/log/runs.jsonl
check "next workers record their own runs" grep -q '"job":"next"' "$home2/log/runs.jsonl"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude >/dev/null 2>&1
check "a job that dies after it starts records the error and its exit" sh -c "tail -1 '$home2/log/runs.jsonl' | grep -q '\"exit\":1,\"result\":\"error: no notes file'"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$J" pause retro >/dev/null
FLOW_HOME="$home2" "$P/scripts/lesson.sh" escalation 'local:task/9' "again" >/dev/null
check "a paused job exits at once and spends nothing" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q '^.*paused:' && [ ! -s '$HOST_LOG' ] && tail -1 '$home2/log/runs.jsonl' | grep -q '\"result\":\"paused'"
FLOW_HOME="$home2" "$J" pause next >/dev/null
check "a paused next skips the tracker sync and every worker" sh -c "FLOW_HOME='$home2' '$P/jobs/next.sh' claude --workers 2 | grep -q 'paused' && [ ! -f '$home2/log/next-1.log' ]"
check "a paused next stops a worker started by hand too, recorded as that worker's paused run" sh -c "FLOW_HOME='$home2' '$P/jobs/next.sh' codex --worker 3 | grep -q 'paused' && tail -1 '$home2/log/runs.jsonl' | grep -q '\"job\":\"next-3\",\"host\":\"codex\".*\"result\":\"paused'"
FLOW_HOME="$home2" "$P/jobs/next.sh" codex --worker codex > "$work/worker.out" 2>&1; code=$?
check "a worker label that is not a number is refused, so no worker runs where pause and status cannot see it" sh -c "[ $code = 2 ] && grep -q -- '--worker takes a number from 1; to split the workers across hosts, set jobs.workers' '$work/worker.out' && [ ! -f '$home2/log/next-codex.log' ]"
check "pause is per job: any worker of next obeys next's pause" sh -c "FLOW_PLUGIN='$P' sh -c '. \"\$FLOW_PLUGIN/jobs/_job.sh\"; job=next-codex-1; [ \"\$(job_base)\" = next ] && job=next-2 && [ \"\$(job_base)\" = next ] && job=comments && [ \"\$(job_base)\" = comments ]' '$P/jobs/x'"
FLOW_HOME="$home2" "$J" resume all >/dev/null
check "resume all clears every pause" sh -c "! ls '$home2'/log/*.paused 2>/dev/null"
check "jobs: an unknown job is refused" sh -c "! '$J' history vim 2>/dev/null"
mkdir -p "$work/agents"
cat > "$work/bin/launchctl" <<'SH'
#!/bin/sh
echo "launchctl $*" >> "$LAUNCH_LOG"
case "$1" in
  print) [ -f "$LAUNCH_DIR/${2##*/}.loaded" ] || exit 113; printf '\tstate = not running\n\truns = 3\n\tlast exit code = 0\n' ;;
  bootstrap) touch "$LAUNCH_DIR/$(basename "$3" .plist).loaded" ;;
  bootout) rm -f "$LAUNCH_DIR/${2##*/}.loaded" ;;
esac
SH
chmod +x "$work/bin/launchctl"
export LAUNCH_LOG="$work/launchctl.log" LAUNCH_DIR="$work/agents" FLOW_LAUNCH_AGENTS="$work/agents" FLOW_SCHEDULER=launchd
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\njobs:\n  schedule:\n    next: every 30m --workers 2 --max-steps 15\n    comments: every 2h\n    intake: daily 02:00\n    retro: weekly sun 03:30\n' > "$home2/config.yaml"
lbl="com.$(basename "$repo" | tr 'A-Z' 'a-z').flow"
FLOW_HOME="$home2" "$J" install > "$work/install.out"
check "install writes a launchd agent per scheduled job and loads it" sh -c "[ \$(ls '$work/agents'/*.plist | wc -l) = 4 ] && [ \$(grep -c bootstrap '$LAUNCH_LOG') = 4 ]"
check "install: every 30m is a 1800 s interval, with the job's args" sh -c "grep -q '<integer>1800</integer>' '$work/agents/$lbl.next.plist' && grep -q 'next.sh claude --workers 2 --max-steps 15' '$work/agents/$lbl.next.plist' && grep -q '<integer>7200</integer>' '$work/agents/$lbl.comments.plist'"
check "install: daily and weekly are calendar times, Sunday is 0" sh -c "grep -q '<key>Hour</key><integer>2</integer><key>Minute</key><integer>0</integer>' '$work/agents/$lbl.intake.plist' && grep -q '<key>Minute</key><integer>30</integer><key>Weekday</key><integer>0</integer>' '$work/agents/$lbl.retro.plist'"
cat > "$work/agent_run.py" <<'PY'
import os, plistlib, subprocess, sys, time
agent = plistlib.load(open(sys.argv[1], "rb"))
program = agent["ProgramArguments"]
if not os.path.exists(program[0]):
    program = ["/bin/sh"] + program[1:]
started = time.time()
with open(sys.argv[2], "ab") as log:
    subprocess.run(program, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                   env=dict(os.environ, **agent["EnvironmentVariables"]), timeout=30)
print("%.1f" % (time.time() - started))
PY
agent_jobs_before="$(ls -d "$repo/.flow/jobs" 2>/dev/null)"; mkdir -p "$repo/.flow/jobs"
for j in comments next; do
  printf '#!/bin/sh\necho $$ > "%s/agent-%s.pid"\nsleep 3\n' "$work" "$j" > "$repo/.flow/jobs/$j.sh"; chmod +x "$repo/.flow/jobs/$j.sh"
done
agent_comments_took="$(python3 "$work/agent_run.py" "$work/agents/$lbl.comments.plist" "$work/agent-comments.log")"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$work/agent-comments.pid" ] && break; sleep 0.2; done
check_all "CommentsAgentStarted_ReturnsWhileItsRunIsAlive: the next interval starts a second run beside it" \
  "python3 -c 'import sys; assert float(sys.argv[1]) < 2' '$agent_comments_took' && kill -0 \"\$(cat '$work/agent-comments.pid')\""
agent_next_took="$(python3 "$work/agent_run.py" "$work/agents/$lbl.next.plist" "$work/agent-next.log")"
check_all "NextAgentStarted_RunsUntilItsRunEnds: launchd starts no second next run" \
  "python3 -c 'import sys; assert float(sys.argv[1]) >= 3' '$agent_next_took' && ! kill -0 \"\$(cat '$work/agent-next.pid')\""
kill "$(cat "$work/agent-comments.pid")" 2>/dev/null
rm -f "$repo/.flow/jobs/comments.sh" "$repo/.flow/jobs/next.sh"; [ -n "$agent_jobs_before" ] || rmdir "$repo/.flow/jobs"
FLOW_HOME="$home2" "$J" install next > /dev/null
check "install again unloads the old agent first" sh -c "grep -q 'bootout gui/.*/$lbl.next' '$LAUNCH_LOG'"
FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status: schedule, loaded, launchd's run count, the last run and what it said" sh -c "python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}; n=r[\"next\"]; i=r[\"intake\"]; assert n[\"schedule\"]==\"every 30m\" and n[\"args\"]==\"--workers 2 --max-steps 15\" and n[\"loaded\"] and n[\"launchd\"][\"runs\"]==3, n; assert i[\"last\"][\"outcome\"]==\"failed\" and i[\"last\"][\"result\"].startswith(\"error\"), i; assert r[\"retro\"][\"week\"][\"paused\"]==1' '$work/status.json'"
check "status: the next run of a calendar job is a time, an interval job is due after a long gap" sh -c "python3 -c 'import json,sys,re; r={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}; assert re.match(r\"[A-Z][a-z]{2} \d\d 02:00\", r[\"intake\"][\"next\"]), r[\"intake\"][\"next\"]' '$work/status.json'"
check "status prints a table" sh -c "FLOW_HOME='$home2' '$J' status | grep -q '^| intake | daily 02:00 | scheduled |'"
check "history lists the runs, newest first" sh -c "FLOW_HOME='$home2' '$J' history intake 5 | sed -n 3p | grep -q '| failed | error: no notes file'"
check "install: the agent leaves the workers a run started alive when the run ends" grep -q '<key>AbandonProcessGroup</key><true/>' "$work/agents/$lbl.next.plist"
sed -i.orig '/AbandonProcessGroup/d' "$work/agents/$lbl.next.plist"
FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status: an agent from before AbandonProcessGroup says to reinstall it" sh -c "python3 -c 'import json,sys; n={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}[\"next\"]; assert n[\"stale\"] and n[\"next\"]==\"reinstall: jobs.sh install next\", n' '$work/status.json'"
FLOW_HOME="$home2" "$J" install next > /dev/null; FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status: a reinstalled agent is not stale" sh -c "python3 -c 'import json,sys; n={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}[\"next\"]; assert not n[\"stale\"], n' '$work/status.json'"
# The agent as macOS keeps it once rewritten: keys sorted, tab-indented, each value on its own line.
python3 -c 'import plistlib,sys; d=plistlib.load(open(sys.argv[1],"rb")); plistlib.dump(d,open(sys.argv[1],"wb"))' "$work/agents/$lbl.next.plist"
FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status: an agent with AbandonProcessGroup and its true on separate lines is not stale" sh -c "grep -q '<key>AbandonProcessGroup</key>\$' '$work/agents/$lbl.next.plist' && python3 -c 'import json,sys; n={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}[\"next\"]; assert not n[\"stale\"] and not n[\"next\"].startswith(\"reinstall\"), n' '$work/status.json'"
check "status: the next schedule's --workers 2 is two workers on jobs.host" sh -c "python3 -c 'import json,sys; n={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}[\"next\"]; assert [(w[\"job\"],w[\"host\"]) for w in n[\"workers\"]]==[(\"next-1\",\"claude\"),(\"next-2\",\"claude\")], n[\"workers\"]' '$work/status.json'"
check "status: last skips a paused run; last_run and latest keep it, with its reason" sh -c "python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}[\"retro\"]; assert r[\"last_run\"][\"outcome\"]==\"paused\" and r[\"last_run\"][\"reason\"]==\"the job is paused\", r[\"last_run\"]; assert r[\"latest\"][\"paused\"]==r[\"last_run\"]; assert r[\"last\"] is None or r[\"last\"][\"outcome\"]!=\"paused\", r[\"last\"]' '$work/status.json'"
printf '{"job":"comments","host":"claude","at":"%s","seconds":0,"exit":0,"result":"skipped: run 4242 still going"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$home2/log/runs.jsonl"
FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status: a run a live lock skipped is the comments job's last_run and latest skipped, with why" sh -c "python3 -c 'import json,sys; c={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}[\"comments\"]; s=c[\"latest\"][\"skipped\"]; assert s[\"reason\"]==\"run 4242 still going\" and s[\"host\"]==\"claude\" and c[\"last_run\"]==s, c; assert c[\"last\"] is None or c[\"last\"][\"outcome\"]!=\"skipped\"' '$work/status.json'"
check "status: each worker carries its newest run of any kind" sh -c "python3 -c 'import json,sys; n={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}[\"next\"]; assert all(\"last_run\" in w and \"running\" in w for w in n[\"workers\"]), n[\"workers\"]' '$work/status.json'"
cp "$home2/config.yaml" "$work/config.workers"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\njobs:\n  workers: {claude: 1, codex: 2}\n  schedule:\n    next: every 30m --max-steps 15\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install next > /dev/null; FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status: jobs.workers shows each worker on its host, numbered across the hosts, claude first" sh -c "python3 -c 'import json,sys; n={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}[\"next\"]; assert [(w[\"job\"],w[\"host\"]) for w in n[\"workers\"]]==[(\"next-1\",\"claude\"),(\"next-2\",\"codex\"),(\"next-3\",\"codex\")], n[\"workers\"]' '$work/status.json'"
check "status prints the workers of next under the table, with their hosts" sh -c "FLOW_HOME='$home2' '$J' status > '$work/status.out' && grep -q '^Workers of next:' '$work/status.out' && grep -q '^- next-1 on claude: ' '$work/status.out' && grep -q '^- next-3 on codex: last paused ' '$work/status.out'"
check "install keeps the next command plain: the workers come from the config at each run" grep -q 'next.sh claude --max-steps 15<' "$work/agents/$lbl.next.plist"
printf 'jobs:\n  workers:\n    codex: 1\n    claude: 2\n' > "$work/workers.yaml"
check "jobs.workers as a block map is read too, claude first whatever the order" sh -c "FLOW_PLUGIN='$P' sh -c '. \"\$FLOW_PLUGIN/lib/flow.sh\"; . \"\$FLOW_PLUGIN/lib/host.sh\"; . \"\$FLOW_PLUGIN/lib/workers.sh\"; f=\"\$1\"; config_file() { echo \"\$f\"; }; [ \"\$(jobs_workers | tr \"\\n\" \" \")\" = \"claude:2 codex:1 \" ]' _ '$work/workers.yaml'"
printf 'adapters:\n  default: local\nbase: main\njobs:\n  workers: {claude: 1, vim: 2}\n  schedule:\n    next: every 30m\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install next > "$work/install.out" 2>&1; code=$?
check "install refuses a jobs.workers host other than claude or codex, exit 2, naming its line" sh -c "[ $code = 2 ] && grep -q \"flow: .*config.yaml:5: jobs.workers names the host 'vim'\" '$work/install.out'"
printf 'adapters:\n  default: local\nbase: main\njobs:\n  workers: {claude: two}\n  schedule:\n    next: every 30m\n' > "$home2/config.yaml"
check "run refuses a count that is not a whole number, exit 2" sh -c "FLOW_HOME='$home2' '$J' run next 2>&1 | grep -q \"jobs.workers.claude is 'two'\"; FLOW_HOME='$home2' '$J' run next >/dev/null 2>&1; [ \$? = 2 ]"
printf 'adapters:\n  default: local\nbase: main\njobs:\n  workers: {claude: 1}\n  schedule:\n    next: every 30m --workers 2\n' > "$home2/config.yaml"
check "install refuses jobs.workers beside --workers in the next schedule" sh -c "FLOW_HOME='$home2' '$J' install next 2>&1 | grep -q 'jobs.workers and --workers in jobs.schedule.next both set the workers: keep one'"
cp "$work/config.workers" "$home2/config.yaml"
printf 'jobs:\n  schedule:\n    next: hourly\n' > "$home2/config.yaml"
check "install refuses a schedule it cannot read" sh -c "! FLOW_HOME='$home2' '$J' install next 2>&1 | grep -q 'as $lbl'"
printf 'jobs:\n  schedule:\n    next: every 30m\n    intake: weekly sun 03:30\n' > "$home2/config.yaml"
check "install elsewhere prints the crontab lines" sh -c "FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install | grep -q '^\*/30 \* \* \* \* cd .*next.sh claude' && FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install intake | grep -q '^30 3 \* \* 0 '"
home3="$work/flow home"; mkdir -p "$home3" && cp "$home2/config.yaml" "$home3/config.yaml"
check "the crontab line quotes a flow home with a space" sh -c "FLOW_SCHEDULER=cron FLOW_HOME='$home3' '$J' install next | grep -qF \">> '$home3/log/launchd-next.log' 2>&1\""
printf 'jobs:\n  schedule:\n    next: every 90m\n    comments: every 45m\n    intake: every 15m\n    retro: every 2h\n' > "$home2/config.yaml"
for j in next comments; do
  check "cron refuses $(yaml_get "$home2/config.yaml" jobs.schedule.$j), naming the intervals it can run" sh -c "! FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install $j >/dev/null 2>&1 && FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install $j 2>&1 | grep -q 'minutes that divide 60.*hours that divide 24'"
done
check "cron takes every 15m and every 2h" sh -c "FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install intake | grep -q '^\*/15 \* \* \* \* ' && FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install retro | grep -q '^0 \*/2 \* \* \* '"
printf 'jobs:\n  schedule:\n    next: every 30m ; touch %s/pwned\n' "$work" > "$home2/config.yaml"
check "install refuses an arg that is not a plain option or value and writes nothing" sh -c "! FLOW_HOME='$home2' '$J' install next >/dev/null 2>&1 && FLOW_HOME='$home2' '$J' install next 2>&1 | grep -q 'one option or value' && ! grep -q pwned '$work/agents/$lbl.next.plist'"
check "run refuses it too and runs nothing" sh -c "FLOW_HOME='$home2' '$J' run next >/dev/null 2>&1; c=\$?; sleep 1; [ \$c -ne 0 ] && [ ! -e '$work/pwned' ]"
printf 'jobs:\n  schedule:\n    next: every 30m\n    intake: daily 25:00\n    retro: weekly sun 07:61\n' > "$home2/config.yaml"
check "install refuses a time out of range" sh -c "FLOW_HOME='$home2' '$J' install intake 2>&1 | grep -q 'no time 25:00' && FLOW_HOME='$home2' '$J' install retro 2>&1 | grep -q 'no time 07:61' && ! FLOW_HOME='$home2' '$J' install retro >/dev/null 2>&1"
check "status shows a bad schedule's error in its row and the other jobs as usual" sh -c "FLOW_HOME='$home2' '$J' status > '$work/bad.out' && grep -q '^| intake | error: .*25:00' '$work/bad.out' && grep -q '^| next | every 30m |' '$work/bad.out' && FLOW_HOME='$home2' '$J' status --json | python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(sys.stdin)}; assert \"07:61\" in r[\"retro\"][\"error\"] and \"error\" not in r[\"next\"]'"
printf 'jobs:\n  schedule:\n    next: every 30m\n    comments: every 2h\n' > "$home2/config.yaml"
printf 'the job said this\n' >> "$home2/log/next.log"; printf 'a worker said this\n' > "$home2/log/next-1.log"
check "logs prints the job's log and each worker's" sh -c "FLOW_HOME='$home2' '$J' logs next 5 > '$work/logs.out' && grep -q '^== next.log' '$work/logs.out' && grep -q 'the job said this' '$work/logs.out' && grep -q '^== next-1.log' '$work/logs.out' && grep -q 'a worker said this' '$work/logs.out'"
fakejob="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/comments.sh")"
sleep 1; fakechild="$(pgrep -P "$fakejob")"
mkdir -p "$home2/log/comments-$fakejob.lock" && echo "$fakejob" > "$home2/log/comments-$fakejob.lock/pid"
fakeintake="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/intake.sh")"
mkdir -p "$home2/log/intake.lock" && echo "$fakeintake" > "$home2/log/intake.lock/pid"
check "RunOfAJobThatIsRunning_IsRefused: a job other than comments runs one at a time" sh -c "FLOW_HOME='$home2' '$J' run intake | grep -q 'running already'"
check "RunWhereNoPsRuns_RefusesAJobThatIsRunning: pgrep sees the run, so no second one starts beside it" \
  sh -c "PATH='$refused_ps':\$PATH FLOW_HOME='$home2' '$J' run intake | grep -q 'running already'"
pkill -P "$fakeintake" 2>/dev/null; kill "$fakeintake" 2>/dev/null; rm -rf "$home2/log/intake.lock"
check "status shows a running job" sh -c "FLOW_HOME='$home2' '$J' status --json | python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(sys.stdin)}; assert r[\"comments\"][\"running\"][0][\"pid\"]==$fakejob'"
check "StatusWhereNoPsRuns_ShowsARunningJob: pgrep sees the run, so status never calls it stopped" \
  sh -c "PATH='$refused_ps':\$PATH FLOW_HOME='$home2' '$J' status --json | python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(sys.stdin)}; assert r[\"comments\"][\"running\"][0][\"pid\"]==$fakejob'"
secondjob="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/comments.sh")"
mkdir -p "$home2/log/comments-$secondjob.lock" && echo "$secondjob" > "$home2/log/comments-$secondjob.lock/pid"
check "StatusWithTwoLiveCommentsRuns_ListsBoth: runs of the comments job overlap, and status shows each" sh -c "FLOW_HOME='$home2' '$J' status --json | python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(sys.stdin)}; assert sorted(e[\"pid\"] for e in r[\"comments\"][\"running\"])==sorted([$fakejob,$secondjob])'"
pkill -P "$secondjob" 2>/dev/null; kill "$secondjob" 2>/dev/null; rm -rf "$home2/log/comments-$secondjob.lock"
jobs_dir_before="$(ls -d .flow/jobs 2>/dev/null)"; mkdir -p .flow/jobs && printf '#!/bin/sh\nexec "%s/jobs/comments.sh" "$@"\n' "$P" > .flow/jobs/comments.sh && chmod +x .flow/jobs/comments.sh
runs_before="$(grep -c '"job":"comments"' "$home2/log/runs.jsonl" 2>/dev/null)"
FLOW_HOME="$home2" "$J" run comments >/dev/null 2>&1
wait_for sh -c '[ "$(grep -c "\"job\":\"comments\"" "$1")" != "$2" ]' _ "$home2/log/runs.jsonl" "$runs_before"
check "RunOfCommentsWhileOneIsAlive_StartsASecondRun: a comments run starts beside a live one" [ "$(grep -c '"job":"comments"' "$home2/log/runs.jsonl")" -gt "${runs_before:-0}" ]
rm -f .flow/jobs/comments.sh; [ -n "$jobs_dir_before" ] || rmdir .flow/jobs
FLOW_HOME="$home2" "$J" stop comments >/dev/null
sleep 1
check "stop ends the running run and every process under it" sh -c "[ -n '$fakechild' ] && ! kill -0 $fakejob 2>/dev/null && ! kill -0 $fakechild 2>/dev/null"
sleep 60 & other=$!
mv "$home2/log/comments-$fakejob.lock" "$home2/log/comments-$other.lock" && echo "$other" > "$home2/log/comments-$other.lock/pid"
check "a lock whose pid now runs something else is not a running job" sh -c "FLOW_HOME='$home2' '$J' status --json | python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(sys.stdin)}; assert r[\"comments\"][\"running\"]==[]'"
check "stop leaves that process alone" sh -c "FLOW_HOME='$home2' '$J' stop comments | grep -q 'not running' && kill -0 $other"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
rm -rf "$home2/log/comments-$other.lock"
# Named schedules: one job on several schedules, each its own agent, name and host.
printf 'jobs:\n  schedule:\n    next: every 30m --max-steps 15\n    next-codex: every 30m codex --workers 2 --max-steps 5\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install next-codex > "$work/install.out" 2>&1
check "install: a named schedule is its own agent, running its job as that name (--as) on its host word" sh -c "grep -q 'next-codex: every 30m codex --workers 2 --max-steps 5, as $lbl.next-codex' '$work/install.out' && grep -q '<string>$lbl.next-codex</string>' '$work/agents/$lbl.next-codex.plist' && grep -q 'next.sh codex --as next-codex --workers 2 --max-steps 5<' '$work/agents/$lbl.next-codex.plist' && grep -q 'launchd-next-codex.log' '$work/agents/$lbl.next-codex.plist'"
FLOW_HOME="$home2" "$J" install next >/dev/null 2>&1
check "install: the host word is that schedule's alone, and the plain one has no --as" grep -q 'next.sh claude --max-steps 15<' "$work/agents/$lbl.next.plist"
FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status --json: each row has its name, its job, its host and configured; a named next's workers are <name>-<n> on its host" sh -c "python3 -c 'import json,sys; r={x[\"name\"]:x for x in json.load(open(sys.argv[1]))}; c=r[\"next-codex\"]; n=r[\"next\"]; assert (c[\"job\"],c[\"host\"],c[\"configured\"],c[\"installed\"],c[\"args\"])==(\"next\",\"codex\",True,True,\"--workers 2 --max-steps 5\"), c; assert (n[\"job\"],n[\"host\"],n[\"configured\"])==(\"next\",\"claude\",True), n; assert [(w[\"job\"],w[\"host\"]) for w in c[\"workers\"]]==[(\"next-codex-1\",\"codex\"),(\"next-codex-2\",\"codex\")], c[\"workers\"]; assert (r[\"health\"][\"job\"],r[\"health\"][\"configured\"])==(\"health\",True)' '$work/status.json'"
FLOW_HOME="$home2" "$J" pause next-codex >/dev/null
check "pause takes a schedule name: next-codex holds, next does not" sh -c "[ -f '$home2/log/next-codex.paused' ] && [ ! -f '$home2/log/next.paused' ] && FLOW_HOME='$home2' '$J' status | grep -q '^| next-codex | every 30m on codex .--workers 2 --max-steps 5. | paused |'"
FLOW_HOME="$home2" "$J" resume next-codex >/dev/null
printf 'jobs:\n  schedule:\n    next: every 30m --max-steps 15\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status --json: a schedule installed here that the config no longer names is listed, configured false" sh -c "python3 -c 'import json,sys; r={x[\"name\"]:x for x in json.load(open(sys.argv[1]))}; c=r[\"next-codex\"]; assert (c[\"job\"],c[\"configured\"],c[\"installed\"])==(\"next\",False,True), c; assert r[\"next\"][\"configured\"] and r[\"health\"][\"configured\"]' '$work/status.json' && FLOW_HOME='$home2' '$J' status | grep -q '^| next-codex | none | not in the config: jobs.sh uninstall next-codex |'"
FLOW_HOME="$home2" "$J" uninstall next-codex > "$work/uninstall.out" 2>&1
check "uninstall takes a schedule the config no longer names, and status drops it" sh -c "grep -q '^next-codex: unscheduled' '$work/uninstall.out' && [ ! -f '$work/agents/$lbl.next-codex.plist' ] && grep -q 'bootout gui/.*/$lbl.next-codex' '$LAUNCH_LOG' && ! FLOW_HOME='$home2' '$J' status | grep -q next-codex"
printf 'jobs:\n  schedule:\n    next_codex: every 30m\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install > "$work/install.out" 2>&1; code=$?
check "install refuses a bad schedule name, exit 2, saying what a name is" sh -c "[ $code = 2 ] && grep -q 'flow: no job next_codex: a schedule is one of next comments intake retro health, or one of them, a dash and a label' '$work/install.out' && [ ! -f '$work/agents/$lbl.next_codex.plist' ]"
printf 'jobs:\n  schedule:\n    next-1: every 30m\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install next-1 > "$work/install.out" 2>&1; code=$?
check "install refuses a label that does not start with a letter: next-1 is a worker of next" sh -c "[ $code = 2 ] && grep -q \"the schedule name next-1 has the label '1'\" '$work/install.out' && [ ! -f '$work/agents/$lbl.next-1.plist' ]"
printf 'jobs:\n  schedule:\n    next-x: every 30m gemini --max-steps 1\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install next-x > "$work/install.out" 2>&1; code=$?
check "install refuses a leading word that is no host, exit 2" sh -c "[ $code = 2 ] && grep -q \"starts its args with 'gemini': a leading word is the host, claude or codex\" '$work/install.out' && [ ! -f '$work/agents/$lbl.next-x.plist' ]"
printf 'jobs:\n  codex:\n    effort: max\n  schedule:\n    intake-low: daily 02:00 codex --effort low\n    retro-bad: weekly sun 03:00 codex\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install intake-low >/dev/null 2>&1; code=$?
check "install takes a schedule whose --effort replaces a jobs.<host>.effort the host does not take" sh -c "[ $code = 0 ] && [ -f '$work/agents/$lbl.intake-low.plist' ]"
FLOW_HOME="$home2" "$J" install retro-bad > "$work/install.out" 2>&1; code=$?
check "install still refuses that effort for a schedule without its own --effort" sh -c "[ $code != 0 ] && grep -q 'jobs.codex.effort is max' '$work/install.out' && [ ! -f '$work/agents/$lbl.retro-bad.plist' ]"
FLOW_HOME="$home2" "$J" uninstall intake-low >/dev/null 2>&1
printf 'jobs:\n  schedule:\n    next-x: every 30m local:task/3 --max-steps 1\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install next-x >/dev/null 2>&1
check "install: an item id leading the args is an arg, on jobs.host" grep -q "next.sh claude --as next-x 'local:task/3' --max-steps 1<" "$work/agents/$lbl.next-x.plist"
printf 'jobs:\n  schedule:\n    next-gh12: every 30m codex gh#12 --max-steps 1\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install next-gh12 >/dev/null 2>&1
check "install: a GitHub item id in the args is one arg, quoted for the shell, after the host word" grep -q "next.sh codex --as next-gh12 'gh#12' --max-steps 1<" "$work/agents/$lbl.next-gh12.plist"
printf 'jobs:\n  schedule:\n    next-mine: every 30m --pick mine\npick:\n  mine:\n    assignee: me\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" install next-mine >/dev/null 2>&1
check "install: a named next schedule runs its --pick filter" grep -q "next.sh claude --as next-mine --pick mine<" "$work/agents/$lbl.next-mine.plist"
check "args refuses an arg that starts with a hash, which YAML would read as a comment" sh -c "! python3 -I '$P/scripts/_jobs.py' args 'every 30m #12' 2>/dev/null && python3 -I '$P/scripts/_jobs.py' args 'every 30m #12' 2>&1 | grep -q 'not starting with #'"
check "run refuses a named schedule the config does not name" sh -c "FLOW_HOME='$home2' '$J' run next-y 2>&1 | grep -q 'no schedule next-y: set jobs.schedule.next-y'; FLOW_HOME='$home2' '$J' run next-y >/dev/null 2>&1; [ \$? = 2 ]"
printf 'jobs:\n  schedule:\n    next: every 30m\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$J" uninstall >/dev/null
check "uninstall unloads and removes every agent" sh -c "[ -z \"\$(ls '$work/agents'/*.plist 2>/dev/null)\" ] && [ \$(grep -c bootout '$LAUNCH_LOG') -ge 5 ]"
unset FLOW_LAUNCH_AGENTS FLOW_SCHEDULER
check_all "runs.jsonl: seconds and exit are numbers on every line, result a string" '[ -s "$home2/log/runs.jsonl" ] && python3 -c "import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l); assert type(r[\"seconds\"]) is int and type(r[\"exit\"]) is int and type(r[\"result\"]) is str, l" "$home2/log/runs.jsonl"'
check "LedgerTheTypeCheckReads_HoldsTheRunsOfSeveralJobs: one job's line alone cannot pass it" python3 -I -c 'import json, sys; sys.exit(0 if len({json.loads(line).get("job") for line in open(sys.argv[1])}) > 1 else 1)' "$home2/log/runs.jsonl"

[ "$fails" -eq 0 ] && { echo "jobs: ok"; exit 0; }
echo "jobs: $fails failed"; exit 1

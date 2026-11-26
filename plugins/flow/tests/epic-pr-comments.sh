#!/bin/sh
# shellcheck disable=SC2034,SC2154 # _flow_setup.sh sets fails; the checks' conditions read the names set here
# epic-pr-comments.sh: the comments job on an epic's PR, whose head is the epic branch and whose
# epic holds no claim, on a fake host that records the folder and commit its session starts at.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_github_fixture.sh"
export FLOW_GH_RETRY_WAIT="0 0"
epic='gh#10'; epic_branch='epic/10'; other_tasks='gh#11 gh#12'
copied_file='.env.local'; setup_mark='.setup-ran'
printf 'worktree_copy:\n  - %s\nworktree_setup:\n  - touch %s\nworktree_setup_paths:\n  - README.md\n' "$copied_file" "$setup_mark" >> .flow/config.yaml
printf 'secret\n' > "$copied_file"
printf '.flow/\n%s\n%s\n' "$copied_file" "$setup_mark" >> "$(git rev-parse --git-common-dir)/info/exclude"
git init -q --bare "$work/origin.git" && git remote add origin "$work/origin.git" && git push -q -u origin main
git switch -q -c "$epic_branch" && printf 'drills\n' > drills.txt && git add drills.txt && git commit -qm drills
git push -q -u origin "$epic_branch" && git switch -q main
remote_epic_tip="$(git -C "$work/origin.git" rev-parse "refs/heads/$epic_branch")"
printf 'the body' | gh pr create --base main --head "$epic_branch" --title Drills --body-file - >/dev/null
env -u CLAUDECODE CODEX_THREAD_ID=t "$P/adapters/github/link-pr.sh" "$epic" https://gh/pull/91 >/dev/null
export HOST_LOG="$work/host.log"
export COPIED_FILE="$copied_file" SETUP_MARK="$setup_mark"
cat > "$work/bin/claude" <<'HOST'
#!/bin/sh
printf '%s\t%s\t%s\t%s\t%s\n' "$PWD" "$(git rev-parse HEAD 2>/dev/null)" "$(ls "$COPIED_FILE" 2>/dev/null)" "$(ls "$SETUP_MARK" 2>/dev/null)" "$*" >> "$HOST_LOG"
[ -z "${LEAVE_WORK:-}" ] || printf 'half done\n' > "$LEAVE_WORK"
[ -z "${LEAVE_COMMIT:-}" ] || { printf 'committed\n' > "$LEAVE_COMMIT" && git add -- "$LEAVE_COMMIT" && git commit -qm "$LEAVE_COMMIT"; }
[ -z "${BREAK_ORIGIN:-}" ] || git remote set-url origin "$BREAK_ORIGIN"
HOST
chmod +x "$work/bin/claude"
pass_start() { grep "comments $epic" "$HOST_LOG" | tail -1 | cut -f"$1"; }
pass_start_folder() { pass_start 1; }
pass_start_tip() { pass_start 2; }
pass_start_copied() { pass_start 3; }
pass_start_set_up() { pass_start 4; }
physical() { (cd "$1" 2>/dev/null && pwd -P); }
pool_folders="$(physical "$work/wt-1") $(physical "$work/wt-2")"
in_the_pool() { case " $pool_folders " in *" $(physical "$1") "*) return 0 ;; esac; return 1; }
epic_gate() { "$P/adapters/github/read.sh" "$epic" | jget state.gate; }
epic_gate_message() { jget message < ".flow/gates/$(item_slug "$epic").json"; }

echo "comments job on an epic PR with a free pool"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
check_all "EpicPrWithAFreePool_PassStartsAtTheRemoteEpicTip: the pass commits and pushes on the epic branch, so its session must start in a worktree holding the epic's remote history, not in the main worktree on main" \
  '[ "$(pass_start_tip)" = "$remote_epic_tip" ]'
check_all "EpicPrWithAFreePool_PassWorksInAPoolWorktree: a free pool worktree is the place a pass works in, so the pass takes one rather than a throwaway" \
  'in_the_pool "$(pass_start_folder)"'
check_all "EpicPrWithAFreePool_PassReleasesItsPoolWorktreeWhenItEnds: the epic held no claim before the pass, so keeping the one the pass took would hold a pool worktree nobody works in" \
  '[ -z "$("$P/scripts/steward.sh" find "$epic")" ]'
check_all "EpicPrWithAFreePool_SetupRunsBeforeThePassStarts: the pass builds and tests in its worktree, so worktree_setup must run there as for any claim" \
  '[ "$(pass_start_set_up)" = "$setup_mark" ]'

echo "comments job on an epic PR whose pass could not reach origin when it ended"
BREAK_ORIGIN="$work/unreachable.git" "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
git remote set-url origin "$work/origin.git"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null 2>&1
check_all "EpicPrWhosePassEndedWithOriginUnreachable_UnchangedRunReleasesThePoolWorktree: a run with nothing new starts no pass, so unless it lets go of the clean worktree the last pass kept, nothing ever does" \
  '[ -z "$(pass_start_folder)" ] && [ -z "$("$P/scripts/steward.sh" find "$epic")" ]'

echo "comments job on an epic PR whose pass committed and did not push"
: > "$HOST_LOG"; LEAVE_COMMIT=unpushed.txt "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
committed_in="$(pass_start_folder)"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
check_all "EpicPrWhosePassLeftUnpushedCommits_NextPassStartsInTheSameWorktree: a release would leave the local epic branch ahead of the remote, which every later claim of it refuses, so the next pass must continue in that worktree" \
  '[ -n "$committed_in" ] && [ "$(physical "$(pass_start_folder)")" = "$(physical "$committed_in")" ]'
git -C "$committed_in" reset -q --hard "$remote_epic_tip"; "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1

echo "comments job on an epic PR with every pool worktree claimed"
for task in $other_tasks; do "$P/scripts/steward.sh" claim "$task" >/dev/null 2>&1; done
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
check_all "EpicPrWithAFullPool_PassStartsAtTheRemoteEpicTip: a full pool leaves the epic no pool worktree, so the pass must still start on the epic's remote history in a worktree of its own, not in the main worktree on main" \
  '[ "$(pass_start_tip)" = "$remote_epic_tip" ]'
check_all "EpicPrWithAFullPool_PassRemovesItsThrowawayWorktreeWhenItEnds: a throwaway worktree left behind after a clean pass piles up on disk for every pass on the PR" \
  'throwaway="$(pass_start_folder)"; [ -n "$throwaway" ] && ! in_the_pool "$throwaway" && [ ! -e "$throwaway" ]'
check_all "EpicPrWithAFullPool_CopiesReachTheThrowawayBeforeThePassStarts: the build in the throwaway needs the ignored files worktree_copy names, as a pool worktree has them" \
  '[ "$(pass_start_copied)" = "$copied_file" ]'
check_all "EpicPrWithAFullPool_SetupRunsInTheThrowawayBeforeThePassStarts: the pass builds and tests in the throwaway, so worktree_setup must run there as in a pool worktree" \
  '[ "$(pass_start_set_up)" = "$setup_mark" ]'

echo "comments job on an epic PR whose pass left uncommitted work in its throwaway"
: > "$HOST_LOG"; LEAVE_WORK=wip.txt "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
left_in="$(pass_start_folder)"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
check_all "EpicPrWhosePassLeftUncommittedWork_NextPassStartsInTheSameWorktree: removing a worktree with uncommitted work would lose it, so the next pass must continue from it" \
  '[ -n "$left_in" ] && [ "$(physical "$(pass_start_folder)")" = "$(physical "$left_in")" ]'
rm -f "$left_in/wip.txt"; "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1

echo "comments job on an epic PR with no worktree to be had"
python3 - "$FAKE_GH_DIR/issues.json" <<'PYTHON'
import json
import sys

state_path = sys.argv[1]
with open(state_path, encoding="utf-8") as state_file:
    state = json.load(state_file)
state["threads"] = [{"id": "T_7", "isResolved": False, "isOutdated": False, "path": "drills.txt", "line": 1,
                     "comments": {"nodes": [{"databaseId": 701, "body": "Name the drill.", "author": {"login": "chatgpt-codex-connector"}, "createdAt": "t"}]}}]
with open(state_path, "w", encoding="utf-8") as state_file:
    json.dump(state, state_file)
PYTHON
"$P/adapters/github/write-state.sh" "$epic" step=done gate=merge >/dev/null
"$P/jobs/comments.sh" claude >/dev/null 2>&1
git remote set-url origin "$work/unreachable.git"
"$P/jobs/comments.sh" claude >/dev/null 2>&1
check_all "EpicPrWithNoWorktreeToBeHad_RaisesAGateOnTheEpic: the job has no session to ask, so the owner must learn the pass could not work at all" \
  '[ "$(epic_gate)" = escalation ]'
steward_reason="$("$P/scripts/steward.sh" claim "$epic" --branch "$epic_branch" 2>&1 >/dev/null | sed 's/^flow: //' | head -n 1)"
check_all "EpicPrWithNoWorktreeToBeHad_GateNamesTheStewardsReason: the owner can only fix what stops the worktree when the gate says what it is" \
  '[ -n "$steward_reason" ] && case "$(epic_gate_message)" in *"$steward_reason"*) true ;; *) false ;; esac'
git remote set-url origin "$work/origin.git"
"$P/adapters/github/write-state.sh" "$epic" gate=merge >/dev/null
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null 2>&1
check_all "EpicPrWithNoWorktreeToBeHad_PassCountsAsNoneTowardTheTwoPassSkip: a pass that never ran left the threads unread, so the next run must still give them their one more pass" \
  '[ -n "$(pass_start_folder)" ]'

[ "$fails" -eq 0 ] && { echo "epic-pr-comments: ok"; exit 0; }
echo "epic-pr-comments: $fails failed"; exit 1

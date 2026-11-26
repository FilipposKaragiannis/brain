#!/bin/sh
# shellcheck disable=SC2034,SC2154 # _base_fixture.sh and _verify_fixture.sh set plugin, work, here, worktree and root; the checks' conditions read the names set here
# pr-ready.sh: the check the pr step runs before it opens a PR, on the local adapter in throwaway
# repos. A report made at HEAD on a clean worktree passes; a report from an older commit, a
# worktree with a changed, new or staged file outside .flow/, and a missing report or one with no
# commit refuse and say why; a change under .flow/ alone is no reason to refuse.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

# pr_ready: runs scripts/pr-ready.sh in the worktree; its output and exit code are the function's.
pr_ready() { (cd "$worktree" && "$plugin/scripts/pr-ready.sh" "$item" 2>&1); }
# report_at <commit>: writes a verify report that names the commit.
report_at() { printf '{"status":"pass","head":"%s","checks":[]}\n' "$1" > "$reports/verify.json"; }
head_commit() { git -C "$worktree" rev-parse HEAD; }

echo "pr-ready: a report made at HEAD"
new_item current "  ok: 'true'"
report_at "$(head_commit)"
refusal="$(pr_ready)"; current_code=$?
check "ReportAtHeadOnACleanWorktree_ExitsZero: nothing differs from what verify checked" '[ "$current_code" -eq 0 ]'
check "ReportAtHeadOnACleanWorktree_SaysNothing: a pass prints no reason" '[ -z "$refusal" ]'
mkdir -p "$worktree/.flow/reports/other" && printf 'x\n' > "$worktree/.flow/reports/other/note.md"
pr_ready >/dev/null; flow_only_code=$?
check "ChangeUnderTheFlowFolderOnly_ExitsZero: flow's own files are no change verify missed" '[ "$flow_only_code" -eq 0 ]'

echo "pr-ready: a report made on another commit"
verified_head="$(head_commit)"
report_at "$verified_head"
printf 'more\n' > "$worktree/later.txt" && git -C "$worktree" add -A && git -C "$worktree" commit -qm later
refusal="$(pr_ready)"; older_code=$?
check "ReportFromAnOlderCommit_ExitsOne: the PR would hold a commit verify never checked" '[ "$older_code" -eq 1 ]'
check "ReportFromAnOlderCommit_NamesBothCommits: the owner sees which two differ" \
  'printf "%s" "$refusal" | grep -q -- "$verified_head" && printf "%s" "$refusal" | grep -q -- "$(head_commit)"'
report_at "$(head_commit)"
pr_ready >/dev/null; renewed_code=$?
check "ReportRenewedAtHead_ExitsZero: running verify again clears the refusal" '[ "$renewed_code" -eq 0 ]'

echo "pr-ready: changes outside the flow folder"
report_at "$(head_commit)"
printf 'edit\n' >> "$worktree/change.txt"
refusal="$(pr_ready)"; edited_code=$?
check "UncommittedEditToATrackedFile_ExitsOne: verify ran before that edit" '[ "$edited_code" -eq 1 ]'
check "UncommittedEditToATrackedFile_NamesTheFile: the owner sees what to commit" 'printf "%s" "$refusal" | grep -q change.txt'
git -C "$worktree" checkout -q -- change.txt
printf 'new\n' > "$worktree/untracked.txt"
pr_ready >/dev/null; untracked_code=$?
check "NewUntrackedFile_ExitsOne: a file verify never saw is outside the report" '[ "$untracked_code" -eq 1 ]'
rm -f "$worktree/untracked.txt"
printf 'staged\n' > "$worktree/staged.txt" && git -C "$worktree" add staged.txt
pr_ready >/dev/null; staged_code=$?
check "StagedFileNotCommitted_ExitsOne: a staged change is still no part of the commit" '[ "$staged_code" -eq 1 ]'
git -C "$worktree" reset -q -- staged.txt; rm -f "$worktree/staged.txt"
printf 'look-alike\n' > "$worktree/.flowrc"
pr_ready >/dev/null; look_alike_code=$?
check "NewFileWhoseNameStartsWithFlow_ExitsOne: only the .flow folder itself is flow's own" '[ "$look_alike_code" -eq 1 ]'
rm -f "$worktree/.flowrc"
rm -f "$worktree/change.txt"
pr_ready >/dev/null; deleted_code=$?
check "TrackedFileDeletedNotCommitted_ExitsOne: the commit still holds the file verify checked, the worktree does not" '[ "$deleted_code" -eq 1 ]'
git -C "$worktree" checkout -q -- change.txt
mkdir -p "$worktree/.flow/moved" && git -C "$worktree" mv change.txt .flow/moved/change.txt
pr_ready >/dev/null; moved_in_code=$?
check "TrackedFileMovedIntoTheFlowFolder_ExitsOne: the file leaves its place outside .flow/, a change verify never saw" '[ "$moved_in_code" -eq 1 ]'
git -C "$worktree" mv .flow/moved/change.txt change.txt

echo "pr-ready: no usable report"
rm -f "$reports/verify.json"
refusal="$(pr_ready)"; missing_code=$?
check "NoVerifyReport_ExitsOne: nothing shows verify ran" '[ "$missing_code" -eq 1 ]'
printf '{"status":"pass","checks":[]}\n' > "$reports/verify.json"
pr_ready >/dev/null; headless_code=$?
check "ReportWithNoCommit_ExitsOne: a report that names no commit proves nothing about HEAD" '[ "$headless_code" -eq 1 ]'

if [ "$fails" -eq 0 ]; then echo "pr-ready: ok"; else echo "pr-ready: $fails failed"; exit 1; fi

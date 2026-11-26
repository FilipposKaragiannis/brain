#!/bin/sh
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
git init -q --bare "$work/origin.git" && git remote add origin "$work/origin.git" && git push -q -u origin main
git switch -q -c "$epic_branch" && printf 'drills\n' > drills.txt && git add drills.txt && git commit -qm drills
git push -q -u origin "$epic_branch" && git switch -q main
remote_epic_tip="$(git -C "$work/origin.git" rev-parse "refs/heads/$epic_branch")"
printf 'the body' | gh pr create --base main --head "$epic_branch" --title Drills --body-file - >/dev/null
env -u CLAUDECODE CODEX_THREAD_ID=t "$P/adapters/github/link-pr.sh" "$epic" https://gh/pull/91 >/dev/null
export HOST_LOG="$work/host.log"
printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$PWD" "$(git rev-parse HEAD 2>/dev/null)" "$*" >> "$HOST_LOG"\n' > "$work/bin/claude"
chmod +x "$work/bin/claude"
pass_start_tip() { grep "comments $epic" "$HOST_LOG" | tail -1 | cut -f2; }

echo "comments job on an epic PR with a free pool"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
check_all "EpicPrWithAFreePool_PassStartsAtTheRemoteEpicTip: the pass commits and pushes on the epic branch, so its session must start in a worktree holding the epic's remote history, not in the main worktree on main" \
  '[ "$(pass_start_tip)" = "$remote_epic_tip" ]'

echo "comments job on an epic PR with every pool worktree claimed"
for task in $other_tasks; do "$P/scripts/steward.sh" claim "$task" >/dev/null 2>&1; done
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude "$epic" >/dev/null 2>&1
check_all "EpicPrWithAFullPool_PassStartsAtTheRemoteEpicTip: a full pool leaves the epic no pool worktree, so the pass must still start on the epic's remote history in a worktree of its own, not in the main worktree on main" \
  '[ "$(pass_start_tip)" = "$remote_epic_tip" ]'

[ "$fails" -eq 0 ] && { echo "epic-pr-comments: ok"; exit 0; }
echo "epic-pr-comments: $fails failed"; exit 1

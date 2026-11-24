#!/bin/sh
# commit-once.sh: an agent's commit runs format and each gate once, however it is staged. The agent
# hook passes the commit's content and git's own hooks skip that same content; content no hook saw
# runs the checks again. Real commits in a throwaway repo whose core.hooksPath is the plugin's
# hooks/git, with a format command and two gates that each append a line to a log. Exit 0 when
# every check passes, 1 on any failure. run.sh runs it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
hooks="$here/.."
work="$(mktemp -d)"
. "$hooks/../../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$hooks/.."
trap 'sandbox_close $?' EXIT
mkdir -p "$work/offline" "$work/tmp"
for tool in curl wget gh osascript notify-send claude codex; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; TMPDIR="$work/tmp"; export PATH TMPDIR
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

format_log="$work/format.log"
unmarked_log="$work/unmarked.log"
marked_log="$work/marked.log"
once=1
twice=2

cd "$work"
git init -q -b main repo && cd repo
git config user.email t@t && git config user.name t
mkdir -p .standards
cat > .standards/config.json <<JSON
{
  "version": "0.1.0",
  "languages": [
    { "name": "text", "extensions": [".txt"],
      "format": [ { "prefix": "", "command": "echo {files} >> '$format_log'" } ] }
  ],
  "build": "true",
  "protected": [],
  "gates": [
    {"name": "unmarked", "command": "echo ran >> '$unmarked_log'"},
    {"name": "marked", "command": "echo ran >> '$marked_log'", "marker": "[skip-marked]"}
  ]
}
JSON
for file in a b c d; do printf '%s\n' "$file" > "$file.txt"; done
git add -A && git commit -qm 'chore: init'
git config core.hooksPath "$hooks/git"

runs() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }

start_case() {
  # $1 case name. A clean worktree and empty logs.
  case_name="$1"
  git reset -q --hard HEAD
  : > "$format_log"; : > "$unmarked_log"; : > "$marked_log"
}

agent_hooks() {
  # $1 command text. Feeds the agent host payload to the format and gates checks.
  payload="$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")"
  printf '%s' "$payload" | "$hooks/check-format.sh" >/dev/null 2>&1 \
    && printf '%s' "$payload" | "$hooks/check-gates.sh" >/dev/null 2>&1 \
    || fail "$case_name: the agent hook blocked $1"
}

run_commit() {
  # $1 command text. Runs it as the agent's shell would, git's hooks included.
  before="$(git rev-parse HEAD)"
  sh -c "$1" >/dev/null 2>&1
  [ "$(git rev-parse HEAD)" != "$before" ] || fail "$case_name: the commit did not land: $1"
}

names_file() { printf '%s\n' "$1" | grep -qwF -- "$2"; }

expect_runs() {
  # $1 test name, $2 log, $3 wanted runs, $4 because.
  check "$1: $4 (ran $(runs "$2"), wanted $3)" [ "$(runs "$2")" -eq "$3" ]
}

echo "an agent's commit runs format and each gate once"
start_case CommitAll
printf 'a2\n' > a.txt
agent_hooks 'git commit -a -m "feat: change a"'; run_commit 'git commit -a -m "feat: change a"'
expect_runs CommitAll_RunsFormatOnce "$format_log" "$once" "git's hooks skip the format check the agent hook passed for the same content"
expect_runs CommitAll_RunsTheUnmarkedGateOnce "$unmarked_log" "$once" "pre-commit skips the gate the agent hook passed"
expect_runs CommitAll_RunsTheMarkedGateOnce "$marked_log" "$once" "commit-msg skips the gate the agent hook passed"

start_case PathspecCommit
printf 'c2\n' > c.txt; printf 'd2\n' > d.txt
agent_hooks 'git commit -m "feat: change c" c.txt'; run_commit 'git commit -m "feat: change c" c.txt'
expect_runs PathspecCommit_RunsFormatOnce "$format_log" "$once" "the agent hook predicts the pathspec commit, d.txt left out"
expect_runs PathspecCommit_RunsTheUnmarkedGateOnce "$unmarked_log" "$once" "pre-commit sees the content the agent hook passed"
expect_runs PathspecCommit_RunsTheMarkedGateOnce "$marked_log" "$once" "commit-msg sees the content the agent hook passed"

start_case IncludeCommit
printf 'b2\n' > b.txt; git add b.txt; printf 'c3\n' > c.txt
agent_hooks 'git commit -i -m "feat: change b and c" c.txt'; run_commit 'git commit -i -m "feat: change b and c" c.txt'
expect_runs IncludeCommit_RunsFormatOnce "$format_log" "$once" "the agent hook adds c.txt to the staged b.txt as git does"
expect_runs IncludeCommit_RunsTheUnmarkedGateOnce "$unmarked_log" "$once" "pre-commit sees the content the agent hook passed"
expect_runs IncludeCommit_RunsTheMarkedGateOnce "$marked_log" "$once" "commit-msg sees the content the agent hook passed"

start_case AddThenCommit
printf 'e\n' > e.txt
agent_hooks 'git add e.txt && git commit -m "feat: add e"'
agent_formatted="$(cat "$format_log")"
run_commit 'git add e.txt && git commit -m "feat: add e"'
expect_runs AddThenCommit_RunsFormatOnce "$format_log" "$once" "git's hooks skip the format check the agent hook passed with e.txt added"
expect_runs AddThenCommit_RunsTheUnmarkedGateOnce "$unmarked_log" "$once" "pre-commit sees the content the agent hook passed"
expect_runs AddThenCommit_RunsTheMarkedGateOnce "$marked_log" "$once" "commit-msg sees the content the agent hook passed"
check "AddThenCommit_FormatsTheAddedFile: the agent hook formats e.txt, which the earlier add stages ($agent_formatted)" names_file "$agent_formatted" e.txt

start_case AddAllThenCommit
printf 'f\n' > f.txt; printf 'a6\n' > a.txt
agent_hooks 'git add -A && git commit -m "feat: add f"'; run_commit 'git add -A && git commit -m "feat: add f"'
expect_runs AddAllThenCommit_RunsFormatOnce "$format_log" "$once" "the agent hook stages every change as git add -A does"
expect_runs AddAllThenCommit_RunsTheUnmarkedGateOnce "$unmarked_log" "$once" "pre-commit sees the content the agent hook passed"
expect_runs AddAllThenCommit_RunsTheMarkedGateOnce "$marked_log" "$once" "commit-msg sees the content the agent hook passed"

echo "a commit outside an agent is checked in full"
start_case HumanCommit
printf 'a3\n' > a.txt
run_commit 'git commit -a -m "feat: change a again"'
expect_runs HumanCommit_RunsFormat "$format_log" "$once" "no agent hook passed this content, so pre-commit runs format"
expect_runs HumanCommit_RunsTheUnmarkedGate "$unmarked_log" "$once" "no agent hook passed this content, so pre-commit runs the gate"
expect_runs HumanCommit_RunsTheMarkedGate "$marked_log" "$once" "no agent hook passed this content, so commit-msg runs the gate"

echo "content no hook saw runs the checks again"
start_case EditToCommittedFileBetweenHooks
printf 'a4\n' > a.txt
agent_hooks 'git commit -a -m "feat: change a once more"'
printf 'a5\n' > a.txt
run_commit 'git commit -a -m "feat: change a once more"'
expect_runs EditToCommittedFileBetweenHooks_RunsFormatAgain "$format_log" "$twice" "the commit holds a.txt as no hook formatted it"
expect_runs EditToCommittedFileBetweenHooks_RunsTheUnmarkedGateAgain "$unmarked_log" "$twice" "the commit holds a.txt as no gate saw it"
expect_runs EditToCommittedFileBetweenHooks_RunsTheMarkedGateAgain "$marked_log" "$twice" "the commit holds a.txt as no gate saw it"

start_case EditToFileOutsideTheCommitBetweenHooks
printf 'b3\n' > b.txt; git add b.txt
agent_hooks 'git commit -m "feat: change b"'
printf 'd3\n' > d.txt
run_commit 'git commit -m "feat: change b"'
expect_runs EditToFileOutsideTheCommitBetweenHooks_RunsTheUnmarkedGateAgain "$unmarked_log" "$twice" "a gate's build reads d.txt, which changed after the agent hook"
expect_runs EditToFileOutsideTheCommitBetweenHooks_RunsTheMarkedGateAgain "$marked_log" "$twice" "a gate's build reads d.txt, which changed after the agent hook"

start_case AddThenEditThenCommitAll
printf 'g\n' > g.txt
agent_hooks 'git add g.txt && echo x >> a.txt && git commit -a -m "feat: add g"'
run_commit 'git add g.txt && echo x >> a.txt && git commit -a -m "feat: add g"'
expect_runs AddThenEditThenCommitAll_RunsFormatAgain "$format_log" "$twice" "the commit holds a.txt as the command left it, which no hook formatted"
expect_runs AddThenEditThenCommitAll_RunsTheUnmarkedGateAgain "$unmarked_log" "$twice" "the commit holds a.txt as the command left it, which no gate saw"
expect_runs AddThenEditThenCommitAll_RunsTheMarkedGateAgain "$marked_log" "$twice" "the commit holds a.txt as the command left it, which no gate saw"

echo "throwaway indexes"
leftovers="$(find "$TMPDIR" "$(git rev-parse --git-dir)" -name 'standards-index*' 2>/dev/null)"
check "AgentCommit_LeavesNoTempIndex: every check removes the throwaway index it built ($leftovers)" [ -z "$leftovers" ]

[ "$fails" -eq 0 ] && echo "commit-once: ok" || { echo "commit-once: $fails failed"; exit 1; }

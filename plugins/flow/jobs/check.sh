#!/bin/sh
# Check job: runs one of the project's own checks from a clean checkout of the base branch.
#   jobs/check.sh <claude|codex> --as check-<name>
# The check is jobs.checks.<name> in .flow/config.yaml, a command and a schedule; scripts/jobs.sh
# runs each as the schedule check-<name>, with its own lock, log, pause and history. The host word
# is the one every job takes; a check starts no session. A run fetches the base (base in the
# config, default main) in the main worktree, so a check never runs in a claimed worktree or on
# what one holds; when the fetch fails it says so and takes origin/<base> as the last fetch left
# it, else the local <base>. It checks that commit out detached in a shared clone under
# <flow home>/check-runs/<name>, which no worktree list shows, and runs no project setup: a check
# that needs its dependencies installs them in its command. The command runs there in sh, its
# output written to <flow home>/log/check-<name>.out, replaced each run, and added to the job log.
# The clone goes when the run ends, by a pass, a fail or a stop; one a killed run left goes at the
# next run's start. The run's line: done: passed at <commit>, exit 0; failed: exited <code> at
# <commit>: <the output's last line>, exit 1; error: could not check out <base>: <why>, exit 1; a
# malformed entry is an error naming its line in the config, exit 2.
# Whether the check passed last lives in <flow home>/log/check-<name>.state, as passed, failed or
# failed <bug id>, since runs.jsonl is cut long before a weekly check's last run would fall out.
# A fail after a pass files one bug through scripts/new.sh in the main worktree, so adapters.bug
# picks the tracker, its body the tail of the output; the line then ends with the bug's id. A fail
# after a fail files none and ends still failing, with the bug's id when there is one; a first fail
# files none either, as no pass came before it. A bug new.sh cannot file leaves the state passed,
# so the next fail tries again, and the line says why. A run that stops before its command ends,
# by a checkout error, a pause, a skip or a stop, leaves the state as it was.
set -u
job=check
. "$(dirname "$0")/_job.sh"
. "$FLOW_PLUGIN/lib/scheduled_checks.sh"
# The characters of the output's last line the run's line keeps, so one long line never fills the
# run history.
check_said_length=200
# The output's last lines a bug's body holds, and the bytes they are cut to, so one huge line can
# never make the tracker refuse every bug.
bug_output_lines=40
bug_output_bytes=8000
# The shortest fence markdown takes for a code block.
shortest_fence_length=3
host="${1:-}"; shift || true
[ $# -eq 0 ] || die "unknown option $1" 2
check_name="${job#check-}"
[ "$check_name" != "$job" ] || die "a check runs as --as check-<name>, its name a key under jobs.checks in .flow/config.yaml" 2
job_start "$host"
entry_problem="$(check_problem "$check_name")"
[ -z "$entry_problem" ] || { job_say "error: $entry_problem"; exit 2; }

main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
base="$(cfg_or base main)"
check_command="$(cfg "jobs.checks.$check_name.command")"
checkout="$(check_checkout "$check_name")"
output="$(check_output "$check_name")"
state_file="$(job_log_dir)/$job.state"
check_end() { rm -rf "$checkout"; job_end "$1"; }
trap 'check_end $?' EXIT

# fetch_base_branch: fetches the base from origin into origin/<base>, and says so when it cannot.
fetch_base_branch() {
  git -C "$main" remote get-url origin >/dev/null 2>&1 || return 0
  fetch_said="$(git -C "$main" fetch -q origin "$base" 2>&1)" && return 0
  job_say "could not fetch $base, so the check runs on the $base fetched last: $(printf '%s\n' "$fetch_said" | tail -n 1)"
}
# base_commit: the base's commit, origin/<base> as the last fetch left it, else the local <base>.
base_commit() {
  git -C "$main" rev-parse -q --verify "refs/remotes/origin/$base^{commit}" 2>/dev/null \
    || git -C "$main" rev-parse -q --verify "refs/heads/$base^{commit}" 2>/dev/null
}
# check_out_base <commit>: clones the main worktree's repository into the check's folder and checks
# the commit out there; when git cannot, prints its last line and returns 1.
check_out_base() {
  mkdir -p "$(check_runs_folder)"
  checkout_said="$(git clone -q --shared --no-checkout "$main" "$checkout" 2>&1 && git -C "$checkout" checkout -q --detach "$1" 2>&1)" && return 0
  printf '%s\n' "$checkout_said" | tail -n 1
  return 1
}
# output_tail: the output's last lines, cut to the bytes a bug's body takes, with the broken
# character the byte cut can leave at its start dropped.
output_tail() { tail -n "$bug_output_lines" "$output" | tail -c "$bug_output_bytes" | iconv -c -f UTF-8 -t UTF-8; }
# fence_for <text>: a fence of backticks one longer than the longest run of them in the text, so
# the text cannot close it.
fence_for() {
  fence_length="$(printf '%s\n' "$1" | grep -o '``*' | awk -v shortest="$((shortest_fence_length - 1))" \
    'BEGIN { longest = shortest } length($0) > longest { longest = length($0) } END { print longest + 1 }')"
  printf "%${fence_length}s" '' | tr ' ' '`'
}
# bug_body <exit code> <time>: the bug's body in the item shape, the output's tail in its notes.
bug_body() {
  command_fence="$(fence_for "$check_command")"
  tail_text="$(output_tail)"
  tail_fence="$(fence_for "$tail_text")"
  printf '## Problem\n\nThe scheduled check %s runs this command from a clean checkout of %s at %s:\n\n%s\n%s\n%s\n\nIt passed on its run before, and at %s it exited %s.\n\n' \
    "$check_name" "$base" "$base_commit_id" "$command_fence" "$check_command" "$command_fence" "$2" "$1"
  printf '## Outcome\n\nThe scheduled check %s passes again on %s.\n\n' "$check_name" "$base"
  printf '## Acceptance\n\n- [ ] `jobs.sh run %s` passes\n\n' "$job"
  printf '## Notes\n\nThe last %s lines of the output, cut to its last %s bytes:\n\n%s\n%s\n%s\n' \
    "$bug_output_lines" "$bug_output_bytes" "$tail_fence" "$tail_text" "$tail_fence"
}
# file_bug <exit code>: files the bug for the failed run in the main worktree's tracker and prints
# its id; when new.sh cannot, prints its last line and returns 1.
file_bug() {
  bug_errors="$(mktemp)"
  bug_id="$(bug_body "$1" "$(now_iso)" | (cd "$main" && "$FLOW_PLUGIN/scripts/new.sh" bug "Scheduled check $check_name fails" --body-file -) 2>"$bug_errors")"
  bug_exit=$?
  bug_said="$(tail -n 1 "$bug_errors")"; rm -f "$bug_errors"
  [ "$bug_exit" -ne 0 ] || [ -z "$bug_id" ] || { printf '%s' "$bug_id"; return 0; }
  printf '%s' "${bug_said:-new.sh exited $bug_exit and printed no id}" | cut -c "1-$check_said_length"
  return 1
}

rm -rf "$checkout"
fetch_base_branch
base_commit_id="$(base_commit)"
[ -n "$base_commit_id" ] || { job_say "error: could not check out $base: neither origin/$base nor $base is a commit here"; exit 1; }
checkout_failure="$(check_out_base "$base_commit_id")" || { job_say "error: could not check out $base: $checkout_failure"; exit 1; }
short_commit_id="$(git -C "$main" rev-parse --short "$base_commit_id")"
job_say "running at $short_commit_id in $checkout"
(cd "$checkout" && exec sh -c "$check_command") < /dev/null > "$output" 2>&1
check_exit=$?
cat "$output" >> "$(job_log_dir)/$job.log"
[ "$check_exit" -ne 0 ] || { printf 'passed\n' > "$state_file"; job_say "done: passed at $short_commit_id"; exit 0; }
failure_line="failed: exited $check_exit at $short_commit_id: $(tail -n 1 "$output" | cut -c "1-$check_said_length")"
previous_state="$(sed -n 1p "$state_file" 2>/dev/null)"
case "$previous_state" in
  passed)
    if filing_result="$(file_bug "$check_exit")"; then
      printf 'failed %s\n' "$filing_result" > "$state_file"; failure_line="$failure_line; filed bug $filing_result"
    else
      failure_line="$failure_line; the bug could not be filed: $filing_result"
    fi ;;
  "failed "?*) failure_line="$failure_line; still failing, bug ${previous_state#failed }" ;;
  failed) failure_line="$failure_line; still failing" ;;
  *) printf 'failed\n' > "$state_file" ;;
esac
job_say "$failure_line"
exit 1

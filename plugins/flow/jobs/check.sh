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
set -u
job=check
. "$(dirname "$0")/_job.sh"
. "$FLOW_PLUGIN/lib/scheduled_checks.sh"
# The characters of the output's last line the run's line keeps, so one long line never fills the
# run history.
check_said_length=200
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
[ "$check_exit" -ne 0 ] || { job_say "done: passed at $short_commit_id"; exit 0; }
job_say "failed: exited $check_exit at $short_commit_id: $(tail -n 1 "$output" | cut -c "1-$check_said_length")"
exit 1

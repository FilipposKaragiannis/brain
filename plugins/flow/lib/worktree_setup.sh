# The worktree_setup commands of .flow/config.yaml in a pool worktree, and the commit they last
# ran at there. Sourced by scripts/steward.sh and lib/base.sh.

setup_poll_seconds=1

setup_record_file() { printf '%s/.flow/setup-commit' "$1"; }
setup_pid_file() { printf '%s/.flow/setup-pid' "$1"; }

run_setup_commands() {
  setup_status=0
  setup_commands="$(cfg worktree_setup)"
  while IFS= read -r setup_command; do
    [ -n "$setup_command" ] || continue
    if (cd "$1" && sh -c "$setup_command" </dev/null); then echo "setup: $setup_command"
    else echo "flow: worktree_setup failed in $1: $setup_command" >&2; setup_status=1; fi
  done <<EOF
$setup_commands
EOF
  return "$setup_status"
}

set_up_and_record() {
  mkdir -p "$1/.flow" && printf '%s\n' "$$" > "$(setup_pid_file "$1")"
  rm -f "$(setup_record_file "$1")"
  setup_start_commit="$(git -C "$1" rev-parse HEAD)"
  if run_setup_commands "$1"; then printf '%s\n' "$setup_start_commit" > "$(setup_record_file "$1")"; fi
  rm -f "$(setup_pid_file "$1")"
}

setup_running() {
  running_setup_pid="$(cat "$(setup_pid_file "$1")" 2>/dev/null)"
  case "$running_setup_pid" in '' | *[!0-9]*) return 1 ;; esac
  kill -0 "$running_setup_pid" 2>/dev/null
}

wait_for_running_setup() {
  setup_running "$1" || return 0
  echo "flow: waiting for the worktree_setup running in $(basename "$1")" >&2
  while setup_running "$1"; do sleep "$setup_poll_seconds"; done
}

setup_outdated() {
  setup_globs="$(cfg worktree_setup_paths)"
  [ -n "$setup_globs" ] || return 1
  recorded_commit="$(cat "$(setup_record_file "$1")" 2>/dev/null)"
  case "$recorded_commit" in '' | *[!0-9a-f]*) return 0 ;; esac
  git -C "$1" cat-file -e "$recorded_commit^{commit}" 2>/dev/null || return 0
  setup_changed_paths="$(git -C "$1" diff -z --name-only --no-renames "$recorded_commit" HEAD -- | tr '\0' '\n')"
  any_path_matches "$setup_globs" "$setup_changed_paths"
}

any_path_matches() {
  while IFS= read -r setup_glob; do
    [ -n "$setup_glob" ] && path_list_matches "$setup_glob" "$2" && return 0
  done <<EOF
$1
EOF
  return 1
}

path_list_matches() {
  while IFS= read -r changed_path; do
    [ -n "$changed_path" ] && glob_match "$1" "$changed_path" && return 0
  done <<EOF
$2
EOF
  return 1
}

set_up_again_when_outdated() {
  setup_outdated "$1" || return 0
  echo "flow: running worktree_setup again in $(basename "$1"): it has no setup record, or a worktree_setup_paths file changed since its last setup" >&2
  set_up_and_record "$1"
}

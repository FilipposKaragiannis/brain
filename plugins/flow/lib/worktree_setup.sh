# The worktree_setup commands of .flow/config.yaml and the commit they last ran at in a pool
# worktree. Sourced by scripts/steward.sh. The record is <worktree>/.flow/setup-commit, because
# .flow/ is never part of the work and a release removes only the claim there. A claim runs the
# setup again when a file worktree_setup_paths names differs between that commit and the
# worktree's HEAD; with no record, or a recorded commit git no longer has, it counts as changed.
# A failed command keeps the old record, so the next claim tries again, and the worktree is
# handed out all the same, as after a failed setup when the steward adds a worktree.

setup_record_file() { printf '%s/.flow/setup-commit' "$1"; }

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

record_setup_commit() {
  mkdir -p "$1/.flow" && git -C "$1" rev-parse HEAD > "$(setup_record_file "$1")"
}

setup_outdated() {
  setup_globs="$(cfg worktree_setup_paths)"
  [ -n "$setup_globs" ] || return 1
  recorded_commit="$(cat "$(setup_record_file "$1")" 2>/dev/null)"
  case "$recorded_commit" in '' | *[!0-9a-f]*) return 0 ;; esac
  setup_changed_paths="$(git -C "$1" diff --name-only --no-renames "$recorded_commit" HEAD -- 2>/dev/null)" || return 0
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
  if run_setup_commands "$1"; then record_setup_commit "$1"; fi
}

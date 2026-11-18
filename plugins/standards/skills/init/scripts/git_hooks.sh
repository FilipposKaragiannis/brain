#!/bin/sh
# Sourced by init.sh after the hook copies. It uses init's check, drifted, note, tmpfile, scope and
# main_worktree_folder, and leaves wanted_hooks_path for init's Next lines.
# A hook call goes before a trailing top-level `exit`: a call after the exit never runs.
hook_with_call() {
  hook_file="$1"; call="$2"; needle="$3"
  CALL="$call" NEEDLE="$needle" awk '
    index($0, ENVIRON["NEEDLE"]) { existing_call = $0; next }
    { hook_lines[++line_count] = $0 }
    END {
      placed_call = (existing_call != "") ? existing_call : ENVIRON["CALL"]
      last_content = line_count
      while (last_content > 0 && hook_lines[last_content] ~ /^[ \t]*$/) last_content--
      call_position = (last_content > 0 && hook_lines[last_content] ~ /^exit([ \t]+[^ \t]+)?[ \t]*(#.*)?$/) ? last_content : line_count + 1
      for (line_number = 1; line_number < call_position; line_number++) print hook_lines[line_number]
      print placed_call
      for (line_number = call_position; line_number <= line_count; line_number++) print hook_lines[line_number]
    }' "$hook_file"
}
hook_call_is_dead() {
  hook_file="$1"; needle="$2"
  NEEDLE="$needle" awk '
    index($0, ENVIRON["NEEDLE"]) { last_call_line = NR }
    /^exit([ \t]|$)/ && !first_exit_line { first_exit_line = NR }
    END { exit !(first_exit_line && last_call_line > first_exit_line) }' "$hook_file"
}
place_call() {
  hook_file="$1"; call="$2"; needle="$3"; outcome="$4"
  hook_with_call "$hook_file" "$call" "$needle" > "$(tmpfile hook)" || return 0
  cmp -s "$(tmpfile hook)" "$hook_file" && return 0
  cat "$(tmpfile hook)" > "$hook_file" && note "$hook_file: standards call $outcome"
}
live_hook_names() {
  hooks_folder="$1"; live_names=""
  for candidate_hook in "$hooks_folder"/*; do
    case "$candidate_hook" in *.sample) continue ;; esac
    if [ -f "$candidate_hook" ] && [ -x "$candidate_hook" ]; then live_names="${live_names:+$live_names, }${candidate_hook##*/}"; fi
  done
  printf '%s' "$live_names"
}
repair() {
  drift_message="$1"; shift
  if [ "$check" -eq 1 ]; then drifted "$drift_message"; else "$@"; fi
}
create_hook() {
  hook_file="$1"; call="$2"
  mkdir -p "${hook_file%/*}" && printf '#!/bin/sh\n%s\n' "$call" > "$hook_file" && chmod +x "$hook_file" && note "$hook_file"
}
rewrite_hook_call() {
  hook_file="$1"; call="$2"; needle="$3"
  CALL="$call" NEEDLE="$needle" awk 'index($0, ENVIRON["NEEDLE"]) { print ENVIRON["CALL"]; next } { print }' "$hook_file" > "$(tmpfile hook)" || return 0
  cat "$(tmpfile hook)" > "$hook_file" && note "$hook_file: standards call now names $main_worktree_folder"
}
wire_hook() {
  hook_file="$1"; call="$2"; needle="$3"
  if [ ! -f "$hook_file" ]; then repair "$hook_file" create_hook "$hook_file" "$call"; return; fi
  if ! grep -qF "$needle" "$hook_file"; then repair "$hook_file lacks the standards call" place_call "$hook_file" "$call" "$needle" "added"; return; fi
  if hook_call_is_dead "$hook_file" "$needle"; then
    repair "$hook_file: the standards call is after an exit and never runs" place_call "$hook_file" "$call" "$needle" "moved before the exit"
  fi
}
wire_clone_hook() {
  hook_file="$1"; call="$2"; needle="$3"
  if [ ! -f "$hook_file" ]; then repair "$hook_file is missing" create_hook "$hook_file" "$call"; return; fi
  if grep -F "$needle" "$hook_file" | grep -qvxF "$call"; then
    repair "$hook_file: the standards call does not name $main_worktree_folder" rewrite_hook_call "$hook_file" "$call" "$needle"
  fi
  wire_hook "$hook_file" "$call" "$needle"
}
wire_clone_hooks() {
  case "$main_worktree_folder" in *'"'*|*'$'*|*'`'*|*'\'*)
    echo "init: $main_worktree_folder holds a double quote, \$, \` or \\, so no hook call can name it; call .standards/hooks/git/pre-commit, commit-msg and pre-push from your hooks by hand"; return ;;
  esac
  clone_hooks_folder="$(git rev-parse --git-path hooks)"
  for clone_hook_name in pre-commit commit-msg pre-push; do
    clone_hook_needle=".standards/hooks/git/$clone_hook_name"
    clone_hook_call="\"$main_worktree_folder/$clone_hook_needle\" \"\$@\" || exit 1  # standards plugin"
    if [ -z "$hooks_path" ]; then wire_clone_hook "$clone_hooks_folder/$clone_hook_name" "$clone_hook_call" "$clone_hook_needle"
    elif [ "$hooks_path" != .standards/hooks/git ] && ! grep -qsF "$clone_hook_needle" "$hooks_path/$clone_hook_name"; then
      echo "init: note: core.hooksPath is $hooks_path, so git runs the hooks there and init leaves them to you. Add this line to $hooks_path/$clone_hook_name: $clone_hook_call"
    fi
  done
}
wire_project_githooks() {
  for project_hook_name in pre-commit commit-msg pre-push; do
    project_hook_needle=".standards/hooks/git/$project_hook_name"
    wire_hook ".githooks/$project_hook_name" "\"\$(git rev-parse --show-toplevel)/$project_hook_needle\" \"\$@\" || exit 1  # standards plugin" "$project_hook_needle"
  done
}
warn_live_hooks() {
  bypass_warning="$1 holds $2; pointing core.hooksPath at $wanted_hooks_path would stop git running them. Call $wanted_hooks_path/pre-commit, commit-msg and pre-push from them, or run init --scope machine."
  if [ "$check" -eq 1 ]; then echo "init: note: $bypass_warning"; else echo "init: $bypass_warning"; fi
}
set_hooks_path() {
  if [ "$check" -eq 1 ]; then drifted "core.hooksPath is unset (wanted $wanted_hooks_path)"
  elif git config core.hooksPath "$wanted_hooks_path" 2>/dev/null; then note "git config core.hooksPath $wanted_hooks_path"
  else echo "init: could not set core.hooksPath. Run: git config core.hooksPath $wanted_hooks_path"; fi
}
wire_hooks_path() {
  if [ -n "$hooks_path" ]; then
    [ "$hooks_path" = "$wanted_hooks_path" ] ||
      echo "init: core.hooksPath is $hooks_path, not $wanted_hooks_path. Call .standards/hooks/git/pre-commit, commit-msg and pre-push from your hooks."
    return 0
  fi
  live_hooks_folder="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/hooks"
  live_hooks="$(live_hook_names "$live_hooks_folder")"
  if [ -n "$live_hooks" ]; then warn_live_hooks "$live_hooks_folder" "$live_hooks"; else set_hooks_path; fi
}
hooks_path="$(git config core.hooksPath 2>/dev/null || true)"
wanted_hooks_path=".standards/hooks/git"
if [ "$scope" = project ] && [ -d .githooks ]; then wire_project_githooks; wanted_hooks_path=".githooks"; fi
if [ "$scope" = machine ]; then wire_clone_hooks; else wire_hooks_path; fi

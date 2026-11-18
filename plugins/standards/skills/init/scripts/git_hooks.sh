#!/bin/sh
# init.sh step 6, sourced after the hook copies: wires git to .standards/hooks/git. It uses init's
# check, drifted, note and tmpfile, and leaves wanted_hooks_path for init's Next lines.
# The plugin never creates .githooks/: a project that has one keeps it and gets one call per hook,
# placed before a trailing top-level `exit` so it runs (a call after the exit never does), and moved
# rather than duplicated on a re-run; a project without one points core.hooksPath (local git
# config, per clone) at the plugin's own folder. init never sets core.hooksPath over live hooks:
# an executable file in the clone's hooks folder that git would stop running once the path moves.
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
hooks_path="$(git config core.hooksPath 2>/dev/null || true)"
if [ -d .githooks ]; then
  for hook in pre-commit commit-msg pre-push; do
    needle=".standards/hooks/git/$hook"
    call="\"\$(git rev-parse --show-toplevel)/$needle\" \"\$@\" || exit 1  # standards plugin"
    if [ ! -f ".githooks/$hook" ]; then
      if [ "$check" -eq 1 ]; then drifted ".githooks/$hook"; else printf '#!/bin/sh\n%s\n' "$call" > ".githooks/$hook" && chmod +x ".githooks/$hook" && note ".githooks/$hook"; fi
    elif ! grep -qF "$needle" ".githooks/$hook"; then
      if [ "$check" -eq 1 ]; then drifted ".githooks/$hook lacks the standards call"
      else place_call ".githooks/$hook" "$call" "$needle" "added"; fi
    elif hook_call_is_dead ".githooks/$hook" "$needle"; then
      if [ "$check" -eq 1 ]; then drifted ".githooks/$hook: the standards call is after an exit and never runs"
      else place_call ".githooks/$hook" "$call" "$needle" "moved before the exit"; fi
    fi
  done
  wanted_hooks_path=".githooks"
else
  wanted_hooks_path=".standards/hooks/git"
fi
live_hooks_folder="$(git rev-parse --git-common-dir 2>/dev/null || echo .git)/hooks"
live_hooks="$(live_hook_names "$live_hooks_folder")"
if [ -z "$hooks_path" ] && [ -n "$live_hooks" ]; then
  bypass_warning="$live_hooks_folder holds $live_hooks; pointing core.hooksPath at $wanted_hooks_path would stop git running them. Call $wanted_hooks_path/pre-commit, commit-msg and pre-push from them, or run init --scope machine."
  if [ "$check" -eq 1 ]; then echo "init: note: $bypass_warning"; else echo "init: $bypass_warning"; fi
elif [ -z "$hooks_path" ]; then
  if [ "$check" -eq 1 ]; then drifted "core.hooksPath is unset (wanted $wanted_hooks_path)"
  elif git config core.hooksPath "$wanted_hooks_path" 2>/dev/null; then note "git config core.hooksPath $wanted_hooks_path"
  else echo "init: could not set core.hooksPath. Run: git config core.hooksPath $wanted_hooks_path"; fi
elif [ "$hooks_path" != "$wanted_hooks_path" ]; then
  echo "init: core.hooksPath is $hooks_path, not $wanted_hooks_path. Call .standards/hooks/git/pre-commit, commit-msg and pre-push from your hooks."
fi

# The worktree_create and worktree_remove commands of .flow/config.yaml. Sourced by
# scripts/steward.sh, which runs them, and skills/init/scripts/init.sh, which checks them.
# A command reaches sh -c with each {path} spelt "$1" and each {base} "$2", and the values as the
# arguments, so no text of a value is ever read as shell.

# worktree_command_filled <command>: the command with each {path} spelt "$1" and each {base} "$2".
worktree_command_filled() {
  printf '%s' "$1" | sed 's/{path}/"$1"/g; s/{base}/"$2"/g'
}

# worktree_command_flaw <key> <command>: why the key's command cannot run, or nothing when it can
# or is unset: it has no {path}, or a placeholder sits inside quotes or after a backslash, where
# the "$1" it becomes would be split into words (double quotes, a backslash) or never expanded
# (single quotes).
worktree_command_flaw() {
  [ -n "$2" ] || return 0
  case "$2" in *'{path}'*) ;; *) printf '%s has no {path}, where flow passes the worktree'\''s folder' "$1"; return 0 ;; esac
  flaw_quoted="$(worktree_placeholder_quoted "$2")"
  [ -z "$flaw_quoted" ] || printf '%s quotes %s; write the placeholder bare, flow quotes the value' "$1" "$flaw_quoted"
}

# worktree_placeholder_quoted <command>: the first {path} or {base} that sits inside single or
# double quotes or right after a backslash, or nothing. A backslash outside single quotes escapes
# the character after it.
worktree_placeholder_quoted() {
  PLACEHOLDER_COMMAND="$1" awk 'BEGIN {
    text = ENVIRON["PLACEHOLDER_COMMAND"]; quote = ""; width = length("{path}")
    for (at = 1; at <= length(text); at++) {
      char = substr(text, at, 1); word = substr(text, at, width); escaped_word = substr(text, at + 1, width)
      if (quote != "\047" && char == "\\" && (escaped_word == "{path}" || escaped_word == "{base}")) { printf "%s", escaped_word; exit }
      else if (quote != "\047" && char == "\\") at++
      else if (quote == "" && (char == "\047" || char == "\"")) quote = char
      else if (quote != "" && char == quote) quote = ""
      else if (quote != "" && (word == "{path}" || word == "{base}")) { printf "%s", word; exit }
    }
  }'
}

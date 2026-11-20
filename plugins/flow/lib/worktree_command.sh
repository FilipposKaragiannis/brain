# The worktree_create and worktree_remove commands of .flow/config.yaml. Sourced by
# scripts/steward.sh, which runs them, and skills/init/scripts/init.sh, which checks them.
# A command reaches sh -c with each {path} spelt "$1" and each {base} "$2", and the values as the
# arguments, so no text of a value is ever read as shell. That holds only for a bare placeholder:
# inside double quotes or after a backslash the "$1" would be split into words, inside single
# quotes never expanded, and inside backticks sh drops the backslash of a \" before it reads the
# quotes, so no quoting there holds. A command with no {path}, or with a placeholder in one of
# those places, is refused.

worktree_command_filled() {
  printf '%s' "$1" | sed 's/{path}/"$1"/g; s/{base}/"$2"/g'
}

worktree_command_flaw() {
  [ -n "$2" ] || return 0
  case "$2" in *'{path}'*) ;; *) printf '%s has no {path}, where flow passes the worktree'\''s folder' "$1"; return 0 ;; esac
  placeholder_flaw="$(worktree_placeholder_flaw "$2")"
  [ -z "$placeholder_flaw" ] || printf '%s %s' "$1" "$placeholder_flaw"
}

worktree_placeholder_flaw() {
  PLACEHOLDER_COMMAND="$1" awk '
    function placeholder(word) { return word == "{path}" || word == "{base}" }
    function quoted(word) { printf "quotes %s; write the placeholder bare, flow quotes the value", word; exit }
    function backticked(word) { printf "has %s inside backticks, which cannot quote it; write $(...) instead, with the placeholder bare", word; exit }
    function open_context(closer) { depth++; quote[depth] = ""; closed_by[depth] = closer; backticks += (closer == "`") }
    function close_context() { backticks -= (closed_by[depth] == "`"); depth-- }
    function opens_substitution(at) { return substr(text, at, 2) == "$(" || (quote[depth] == "" && substr(text, at, 1) == "(") }
    BEGIN {
      text = ENVIRON["PLACEHOLDER_COMMAND"]; width = length("{path}"); depth = 0; backticks = 0; quote[0] = ""; closed_by[0] = ""
      for (at = 1; at <= length(text); at++) {
        char = substr(text, at, 1); state = quote[depth]
        if (backticks > 0 && placeholder(substr(text, at, width))) backticked(substr(text, at, width))
        else if (state != "\047" && char == "\\") { if (placeholder(substr(text, at + 1, width))) quoted(substr(text, at + 1, width)); at++ }
        else if (state != "" && placeholder(substr(text, at, width))) quoted(substr(text, at, width))
        else if (state == "\047") { if (char == "\047") quote[depth] = "" }
        else if (char == "`" && closed_by[depth] == "`") close_context()
        else if (char == "`") open_context("`")
        else if (opens_substitution(at)) { at += (char == "$"); open_context(")") }
        else if (state == "\"") { if (char == "\"") quote[depth] = "" }
        else if (char == ")" && closed_by[depth] == ")") close_context()
        else if (char == "\047" || char == "\"") quote[depth] = char
      }
    }'
}

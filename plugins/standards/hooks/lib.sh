#!/bin/sh
# Shared helpers for the standards hooks. POSIX sh. JSON helpers come from json.sh (generated).
# Every hook reads the host payload on stdin, blocks with exit 2 and the reason on stderr, and
# exits 0 otherwise. The project config lives in <repo>/.standards/config.json.

# The git hooks live one level down (hooks/git/) and init.sh elsewhere (it sets STANDARDS_HOOKS).
for _d in "${STANDARDS_HOOKS:-}" "$(dirname "$0")" "$(dirname "$0")/.."; do
  [ -n "$_d" ] && [ -f "$_d/json.sh" ] && { . "$_d/json.sh"; . "$_d/stamp.sh"; break; }
done

# macOS ships /usr/bin/git as an xcrun shim that fails in sandboxes that block its cache file
# ("Failed to locate 'git'"). When the shim is broken and Xcode's git exists, use that one.
if ! command git --version >/dev/null 2>&1 && [ -x /Applications/Xcode.app/Contents/Developer/usr/bin/git ]; then
  git() { /Applications/Xcode.app/Contents/Developer/usr/bin/git "$@"; }
fi

repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

# The install set of plugin <root>: every file whose content init copies into a project, plus
# init.sh (it shapes the rules files) and the manifest (the version in the block header).
# init stamps its hash; the session-start hook compares.
standards_install_set() {
  for f in "$1"/.claude-plugin/plugin.json "$1"/skills/init/scripts/init.sh "$1"/rules/block.md \
           "$1"/rules/common/*.md "$1"/rules/csharp.md "$1"/codex-agents/*.toml \
           "$1"/hooks/*.sh "$1"/hooks/git/*; do [ -f "$f" ] && echo "$f"; done | sort
}
standards_source_hash() { hash_files $(standards_install_set "$1"); }

main_worktree() { git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p'; }

config_text() {
  root="$(repo_root)" || return 0
  [ -f "$root/.standards/config.json" ] && cat "$root/.standards/config.json"
}

read_payload() { cat 2>/dev/null || true; }

payload_command() { json_get "$1" "tool_input.command"; }

git_segment() {
  # $1 wanted subcommand, $2 shell command text. Prints the first command segment that is a
  # real `git <subcommand>` call (git options such as -C <dir> are skipped), else nothing.
  printf '%s\n' "$2" | awk -v want="$1" '
    function is_git(tok) { return tok ~ /(^|\/)git$/ }
    {
      n = split($0, segs, /&&|\|\||;|\|/)
      for (i = 1; i <= n; i++) {
        seg = segs[i]
        m = split(seg, t, /[ \t]+/)
        g = 0
        for (j = 1; j <= m; j++) if (t[j] != "" && is_git(t[j])) { g = j; break }
        if (g == 0) continue
        sub_cmd = ""
        for (k = g + 1; k <= m; k++) {
          tok = t[k]
          if (tok == "") continue
          if (tok ~ /^-/) {
            if (tok == "-C" || tok == "-c" || tok == "--git-dir" || tok == "--work-tree" || tok == "--namespace" || tok == "--exec-path") k++
            continue
          }
          sub_cmd = tok
          break
        }
        if (sub_cmd == want) { print seg; exit }
      }
    }'
}

commit_has_flag() {
  # $1 segment, $2 long flag (without dashes), $3 short letter. True when the commit carries it.
  printf '%s' "$1" | grep -qE -- "(^|[[:space:]])--$2([[:space:]]|=|$)" && return 0
  [ -n "$3" ] && printf '%s' "$1" | grep -qE -- "(^|[[:space:]])-[A-Za-z]*$3[A-Za-z]*([[:space:]]|$)"
}

commit_message_text() {
  # $1 segment. Prints the -m/--message text and the content of a -F/--file message file.
  printf '%s' "$1" | grep -oE -- '(-m|--message)(=|[[:space:]]+)("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)' \
    | sed -E 's/^(-m|--message)(=|[[:space:]]+)//; s/^["'\'']//; s/["'\'']$//'
  file="$(printf '%s' "$1" | grep -oE -- '(-F|--file)(=|[[:space:]]+)("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)' \
    | head -1 | sed -E 's/^(-F|--file)(=|[[:space:]]+)//; s/^["'\'']//; s/["'\'']$//')"
  [ -n "$file" ] && [ -f "$file" ] && cat "$file"
  return 0
}

commit_has_marker() {
  # $1 segment, $2 marker such as [config]. True when the commit message carries it.
  commit_message_text "$1" | grep -qiF -- "$2"
}

command_code() {
  # $1 command text. Prints the part of it that runs. Heredoc bodies and comments are dropped.
  # Quoted text is dropped when it is prose: more than one word, the value of a message or pattern
  # flag (-m, --message, -F, -e, --grep), or an argument of a text tool (echo, printf, grep, rg,
  # sed, awk, cat). Kept: a one-word quoted argument of any other command ("update-golden" passed
  # to make or dotnet), the quoted argument of `sh -c`, `bash -c` and `eval`, and any $( ) inside
  # double quotes. A forbid gate matches against this, so a doc, a commit message or an echo that
  # names a paused verb does not trip it, but quoting the verb does not hide a run.
  printf '%s\n' "$1" | awk '
    BEGIN { sq = sprintf("%c", 39); dq = sprintf("%c", 34); term = ""; n = 0 }
    {
      if (term != "") { t = $0; sub(/^\t+/, "", t); if (t == term) term = ""; next }
      src[++n] = $0
      p = index($0, "<<")
      if (p > 0 && substr($0, p, 3) != "<<<") {
        s = substr($0, p + 2); sub(/^-/, "", s); sub(/^[ \t]+/, "", s)
        while (substr(s, 1, 1) == sq || substr(s, 1, 1) == dq || substr(s, 1, 1) == "\\") s = substr(s, 2)
        w = ""
        for (k = 1; k <= length(s); k++) { ch = substr(s, k, 1); if (ch ~ /[A-Za-z0-9_]/) w = w ch; else break }
        term = w
      }
    }
    END {
      text = ""
      for (i = 1; i <= n; i++) text = text src[i] "\n"
      len = length(text); i = 1; out = ""; tok = ""; last = ""; cmdword = ""
      while (i <= len) {
        c = substr(text, i, 1)
        if (c == sq || c == dq) {
          q = c; j = i + 1; body = ""; run = ""; depth = 0
          while (j <= len) {
            d = substr(text, j, 1)
            if (depth > 0) {
              if (d == "(") depth++
              else if (d == ")") { depth--; if (depth == 0) { run = run " "; j++; continue } }
              run = run d; j++; continue
            }
            if (q == dq && d == "\\") { j += 2; continue }
            if (q == dq && d == "$" && substr(text, j + 1, 1) == "(") { depth = 1; j += 2; continue }
            if (d == q) break
            body = body d; j++
          }
          prev = (tok != "") ? tok : last
          inert = (cmdword ~ /^(.*\/)?(echo|printf|grep|egrep|fgrep|rg|sed|awk|cat)$/)
          prose = (body ~ /[ \t\n]/ || prev ~ /^(-m|--message|-F|--file|-e|--regexp|--grep)$/ || prev ~ /^--(message|file|grep)=$/)
          keep = (prev == "eval" || prev ~ /^-[A-Za-z]*c$/ || (!inert && !prose))
          if (cmdword == "" && tok == "") cmdword = body
          out = out " " (keep ? body : "") " " run " "
          tok = ""; last = ""; i = j + 1; continue
        }
        if (c == "\\") { out = out substr(text, i, 2); i += 2; continue }
        if (c == "#" && tok == "") { while (i <= len && substr(text, i, 1) != "\n") i++; continue }
        out = out c
        if (c ~ /[ \t\n;|&()<>]/) {
          if (tok != "") { last = tok; if (cmdword == "" && tok !~ /=/) cmdword = tok }
          tok = ""
          if (c ~ /[\n;|&(]/) cmdword = ""
        } else tok = tok c
        i++
      }
      print out
    }'
}

code_has_word() {
  # $1 code text, $2 wanted text. True when the text occurs with no word character (letter, digit,
  # _ or -) directly before or after it: update-golden matches ./update-golden.sh and
  # `dotnet update-golden`, not update-golden-all.
  printf '%s\n' "$1" | T="$2" awk '
    BEGIN { t = ENVIRON["T"]; found = 0 }
    {
      s = $0; base = 0
      while (t != "" && (p = index(s, t)) > 0) {
        before = (base + p > 1) ? substr($0, base + p - 1, 1) : ""
        after = substr($0, base + p + length(t), 1)
        if (before !~ /[A-Za-z0-9_-]/ && after !~ /[A-Za-z0-9_-]/) { found = 1; exit }
        base += p; s = substr(s, p + 1)
      }
    }
    END { exit !found }'
}

# The agent hook and git's own hooks both see an agent's commit. When a check passes in the agent
# hook for a plain `git commit` of the index, it records the index tree; git's pre-commit and
# commit-msg (STANDARDS_FROM_GIT=1) skip that check when the index they see is the same tree,
# recorded in the last 10 minutes. Any other index (a `git add` in the same command, -a, a
# pathspec, a later edit) runs the check again. The record lives in the worktree's git dir.
passed_file() { printf '%s/standards-passed' "$(git rev-parse --git-dir 2>/dev/null)"; }

passed_mark() {
  # $1 check name, $2 commit segment. Records the pass when the commit takes the index as it is.
  [ -z "${STANDARDS_FROM_GIT:-}${STANDARDS_STAGE:-}${STANDARDS_GATES:-}" ] || return 0
  [ "$(commit_diff_args "$2")" = "--cached" ] || return 0
  tree="$(git write-tree 2>/dev/null)" || return 0
  f="$(passed_file)"
  { tail -n 19 "$f" 2>/dev/null; printf '%s %s %s\n' "$1" "$tree" "$(date +%s)"; } > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
  return 0
}

passed_seen() {
  # $1 check name. True in a git hook when the agent hook passed this check for the same index.
  [ -n "${STANDARDS_FROM_GIT:-}" ] || return 1
  tree="$(git write-tree 2>/dev/null)" || return 1
  now="$(date +%s)"
  awk -v c="$1" -v t="$tree" -v now="$now" '$1 == c && $2 == t && now - $3 <= 600 { ok = 1 } END { exit !ok }' "$(passed_file)" 2>/dev/null
}

commit_diff_args() {
  # $1 segment. Prints the git diff arguments that mirror what this commit will stage:
  # -a/--all or a pathspec reads the working tree against HEAD, otherwise the index.
  seg="$1"
  if commit_has_flag "$seg" "all" "a"; then printf 'HEAD'; return; fi
  stripped="$(printf '%s' "$seg" | sed -E \
    's/(-m|--message|-F|--file|-c|-C|--reuse-message|--fixup|--squash|--author|--date|--gpg-sign|-S)(=|[[:space:]]+)("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)//g')"
  positional="$(printf '%s' "$stripped" | sed -E 's/^.*[[:space:]]commit([[:space:]]|$)/ /' \
    | tr ' \t' '\n\n' | grep -vE '^-' | grep -vE '^$' || true)"
  if [ -n "$positional" ]; then printf 'HEAD'; else printf -- '--cached'; fi
}

changed_files() {
  # $1 segment. Added, copied, modified or renamed files this commit will contain.
  # shellcheck disable=SC2046
  git diff $(commit_diff_args "$1") --name-only --diff-filter=ACMR 2>/dev/null || true
}

block() {
  # $1 title, $2 detail lines. Writes the reason to stderr and exits 2. Never call it in a pipeline.
  { echo "standards: $1"; printf '%s\n' "$2"; } >&2
  exit 2
}

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

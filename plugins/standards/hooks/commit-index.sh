#!/bin/sh
# What an agent's commit will hold, and the record that lets git's hooks skip a check the agent
# hook already passed. POSIX sh, sourced by lib.sh.
# The agent hook and git's own hooks both see an agent's commit. Before a check, the agent hook
# builds the index the commit will make (the index as it is, -a, a pathspec with -o or -i) in a
# throwaway file and keys it on two trees: the commit's tree and the tracked working files on top
# of it. When the check passes and the key has not moved, it records the key; git's pre-commit
# and commit-msg (STANDARDS_FROM_GIT=1) skip that check when the index git hands them gives the
# same key, recorded in the last 10 minutes. A content key cannot match other content, so a wrong
# prediction only runs the check again, and so does an edit to any tracked file between the
# hooks. A command it cannot read (-p, --interactive, --pathspec-from-file, git options before
# commit, a quoted or globbed path) records nothing. Untracked files are not in the key: hashing
# them would write their blobs on every commit. The record lives in the worktree's git dir, in its
# own file, so hook copies from before this rule never read its lines.

standards_start_folder="$(pwd)"
passed_window_seconds=600
passed_record_lines=20
commit_path_word='^[A-Za-z0-9._/@+=:,-]+$'

commit_operands_removed() {
  # $1 segment. Prints it without the operands of the options that take one (-m, -F, -C…).
  printf '%s' "$1" | sed -E \
    's/(-m|--message|-F|--file|-c|-C|--reuse-message|--fixup|--squash|--author|--date|--gpg-sign|-S)(=|[[:space:]]+)("[^"]*"|'\''[^'\'']*'\''|[^[:space:]]+)//g'
}

commit_staging() {
  # $1 segment. Prints how the commit stages, one of index, all, only or include, then the paths
  # it names, one per line. Fails when the command cannot be read.
  if [ -n "${STANDARDS_FROM_GIT:-}" ]; then printf 'index\n'; return 0; fi
  printf '%s' "$1" | grep -qE '^[[:space:]]*([^[:space:]]*/)?git[[:space:]]+commit([[:space:]]|$)' || return 1
  short_flags_split="$(printf '%s' "$1" | sed -E 's/(^|[[:space:]])-([A-Za-z]+)([mFcC])([[:space:]=]|$)/\1-\2 -\3\4/g')"
  commit_operands_removed "$short_flags_split" | tr '\n\t' '  ' | awk -v path_word="$commit_path_word" '
    function unreadable() { failed = 1; exit 1 }
    function read_long_option(word) {
      if (word ~ /^--(patch|interactive|pathspec-from-file)(=|$)/) unreadable()
      if (word == "--all") all = 1
      if (word == "--only") only = 1
      if (word == "--include") include = 1
    }
    function read_short_options(word) {
      if (word ~ /p/) unreadable()
      if (word ~ /a/) all = 1
      if (word ~ /o/) only = 1
      if (word ~ /i/) include = 1
    }
    function read_word(word) {
      if (word == "") return
      if (!options_done && word == "--") { options_done = 1; return }
      if (!options_done && word ~ /^--/) { read_long_option(word); return }
      if (!options_done && word ~ /^-/) { read_short_options(word); return }
      if (word !~ path_word) unreadable()
      paths = paths word "\n"
    }
    function staging_mode() {
      if (all + only + include > 1 || (paths == "" && (only || include)) || (paths != "" && all)) unreadable()
      if (paths != "") return include ? "include" : "only"
      return all ? "all" : "index"
    }
    {
      count = split($0, words, / +/); position = 1
      while (position <= count && words[position] == "") position++
      if (words[position] !~ /(^|\/)git$/ || words[position + 1] != "commit") unreadable()
      for (position += 2; position <= count; position++) read_word(words[position])
    }
    END {
      if (failed || NR == 0) exit 1
      printf "%s\n%s", staging_mode(), paths
    }'
}

git_on_index() {
  # $1 index file, then git's arguments. Runs git on that index from the folder the hook started in.
  (
    GIT_INDEX_FILE="$1"; export GIT_INDEX_FILE; shift
    cd "$standards_start_folder" && git "$@" </dev/null 2>/dev/null
  )
}

source_index_path() {
  # Prints the index the commit starts from: the one git hands its hook, else the worktree's own.
  source_path="${GIT_INDEX_FILE:-}"
  [ -n "$source_path" ] || source_path="$(cd "$standards_start_folder" && git rev-parse --git-path index 2>/dev/null)" || return 1
  case "$source_path" in /*) printf '%s' "$source_path" ;; *) printf '%s/%s' "$standards_start_folder" "$source_path" ;; esac
}

write_commit_index() {
  # $1 index file to write, $2 the staging (commit_staging). Fails when git cannot stage it.
  staging_mode="$(printf '%s\n' "$2" | head -n 1)"
  staged_paths="$(printf '%s\n' "$2" | sed '1d')"
  if [ "$staging_mode" = only ]; then
    head_tree=HEAD
    git_on_index "$1" rev-parse -q --verify HEAD >/dev/null || head_tree=--empty
    git_on_index "$1" read-tree "$head_tree" || return 1
  else
    cp "$(source_index_path)" "$1" 2>/dev/null || return 1
  fi
  [ "$staging_mode" != all ] || git_on_index "$1" add -u || return 1
  case "$staging_mode" in only|include) ;; *) return 0 ;; esac
  (
    set -f; IFS='
'
    # shellcheck disable=SC2086
    git_on_index "$1" add -A -- $staged_paths
  )
}

commit_index() {
  # $1 segment. Prints a throwaway index file that holds what the commit will contain, or nothing
  # when the command cannot be read. discard_index_at_exit removes it.
  staging="$(commit_staging "$1")" || return 0
  index_folder="$(mktemp -d "${TMPDIR:-/tmp}/standards-index.XXXXXX" 2>/dev/null)" || return 0
  if write_commit_index "$index_folder/index" "$staging"; then printf '%s' "$index_folder/index"; return 0; fi
  rm -rf "$index_folder"
}

discard_index_at_exit() {
  # $1 index file from commit_index, or empty. Sets this shell's exit trap to remove it.
  [ -n "$1" ] || return 0
  discarded_index_folder="$(dirname "$1")"
  trap 'rm -rf "$discarded_index_folder"' EXIT
  trap 'exit 1' HUP INT TERM
}

commit_key() {
  # $1 index file, or empty. Prints the commit's tree and the tree of the tracked working files on
  # top of it, or nothing when git cannot write either.
  [ -n "$1" ] || return 0
  commit_tree="$(git_on_index "$1" write-tree)" || return 0
  working_index="$1.working"
  working_tree=""
  cp "$1" "$working_index" 2>/dev/null && git_on_index "$working_index" add -u \
    && working_tree="$(git_on_index "$working_index" write-tree)"
  rm -f "$working_index"
  [ -n "$working_tree" ] || return 0
  printf '%s %s' "$commit_tree" "$working_tree"
}

index_files() {
  # $1 index file. Added, copied, modified or renamed files of that index against HEAD.
  git_on_index "$1" diff --cached --name-only --diff-filter=ACMR || true
}

commit_files() {
  # $1 index file from commit_index, or empty, $2 segment. The files this commit will contain.
  if [ -n "$1" ]; then index_files "$1"; return 0; fi
  changed_files "$2"
}

passed_file() { printf '%s/standards-passed-trees' "$(git rev-parse --git-dir 2>/dev/null)"; }

passed_mark() {
  # $1 check name, $2 index file, $3 its key before the check. Records the pass in the agent hook
  # when the key is the same after the check.
  [ -z "${STANDARDS_FROM_GIT:-}${STANDARDS_STAGE:-}${STANDARDS_GATES:-}" ] || return 0
  [ -n "$3" ] && [ "$(commit_key "$2")" = "$3" ] || return 0
  record="$(passed_file)"
  { tail -n "$((passed_record_lines - 1))" "$record" 2>/dev/null; printf '%s %s %s\n' "$1" "$3" "$(date +%s)"; } \
    > "$record.tmp" 2>/dev/null && mv "$record.tmp" "$record" 2>/dev/null
  return 0
}

passed_seen() {
  # $1 check name, $2 key. True in a git hook when the agent hook passed this check for that key.
  [ -n "${STANDARDS_FROM_GIT:-}" ] && [ -n "$2" ] || return 1
  awk -v check="$1" -v key="$2" -v now="$(date +%s)" -v window="$passed_window_seconds" \
    '$1 == check && ($2 " " $3) == key && now - $4 <= window { seen = 1 } END { exit !seen }' "$(passed_file)" 2>/dev/null
}

#!/bin/sh
# What an agent's commit will hold, and the record that lets git's hooks skip a check the agent
# hook already passed. POSIX sh, sourced by lib.sh.
# The agent hook and git's own hooks both see an agent's commit. Before a check, the agent hook
# builds the index the commit will make (the index as it is, the `git add` calls earlier in the
# same command, -a, a pathspec with -o or -i) in a throwaway file and keys it on three trees: the
# commit's tree, the working files tracked on top of it and the working files the worktree's index
# tracks, which git leaves as it was until the commit lands. When the check passes and the key has
# not moved, it records the key; git's pre-commit and commit-msg (STANDARDS_FROM_GIT=1) skip that
# check when the index git hands them gives the same key, recorded in the last 10 minutes. A
# content key cannot match other content, so a wrong prediction only runs the check again, and so
# does an edit to any tracked file between the hooks. A command it cannot read (-p, --interactive,
# --pathspec-from-file, git options before commit, a quoted or globbed path, an earlier cd, git
# call other than add, or add option other than -A, -u or -f) records nothing. Untracked files
# are not in the key: hashing them would write their blobs on every commit. The record lives in
# the worktree's git dir, in its own file, so hook copies from before this rule never read its
# lines. An index copy keeps the index's time (cp -p): git rehashes an entry no older than its
# index, so a copy stamped later trusts a same-size edit made in the second the entry was written.

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

segments_before() {
  # $1 wanted subcommand, $2 shell command text. Prints, one per line, the segments before the one
  # git_segment finds, split as it splits them.
  wanted_segment="$(git_segment "$1" "$2")"
  [ -n "$wanted_segment" ] || return 0
  printf '%s\n' "$2" | wanted_segment="$wanted_segment" awk '
    {
      count = split($0, segments, /&&|\|\||;|\|/)
      for (position = 1; position <= count; position++) {
        if (segments[position] == ENVIRON["wanted_segment"]) exit
        print segments[position]
      }
    }'
}

earlier_adds() {
  # $1 shell command text. Prints the arguments of each `git add` before the commit, one add per
  # line. Fails when an earlier segment is a cd, another git call or an add it cannot read.
  segments_before commit "$1" | tr '\t' ' ' | awk -v path_word="$commit_path_word" '
    function unreadable() { failed = 1; exit 1 }
    function read_add_word(word) {
      if (word == "") return
      if (!options_done && word == "--") options_done = 1
      else if (!options_done && word ~ /^-/) { if (word !~ /^(-A|--all|-u|--update|-f|--force)$/) unreadable() }
      else if (word !~ path_word) unreadable()
      add_arguments = add_arguments " " word
    }
    function read_add(first, count) {
      if (words[first] !~ /(^|\/)git$/ || words[first + 1] != "add") unreadable()
      add_arguments = ""; options_done = 0
      for (position = first + 2; position <= count; position++) read_add_word(words[position])
      print add_arguments
    }
    {
      count = split($0, words, / +/); first = 0
      for (position = count; position >= 1; position--) {
        if (words[position] ~ /^\(*(cd|pushd|popd)$/) unreadable()
        if (words[position] ~ /(^|[\/(])git$/) first = position
      }
      if (first == 0) next
      for (position = 1; position < first; position++) if (words[position] != "") unreadable()
      read_add(first, count)
    }
    END { exit failed }'
}

add_to_index() {
  # $1 index file, $2 the arguments of each `git add`, one add per line. Runs them on that index in
  # order. Fails when one fails.
  while IFS= read -r add_arguments; do
    [ -n "$add_arguments" ] || continue
    (
      set -f; IFS=' '
      # shellcheck disable=SC2086
      git_on_index "$1" add $add_arguments
    ) || return 1
  done <<ADDS
$2
ADDS
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
  if [ -n "${GIT_INDEX_FILE:-}" ]; then printf '%s' "$GIT_INDEX_FILE"; return 0; fi
  worktree_index_path
}

worktree_index_path() {
  # Prints the worktree's own index, which git leaves as it was until the commit lands.
  source_path="$(unset GIT_INDEX_FILE; cd "$standards_start_folder" && git rev-parse --git-path index 2>/dev/null)" || return 1
  case "$source_path" in /*) printf '%s' "$source_path" ;; *) printf '%s/%s' "$standards_start_folder" "$source_path" ;; esac
}

write_commit_index() {
  # $1 index file to write, $2 the staging (commit_staging), $3 the earlier adds (earlier_adds).
  # Fails when git cannot stage it.
  staging_mode="$(printf '%s\n' "$2" | head -n 1)"
  staged_paths="$(printf '%s\n' "$2" | sed '1d')"
  cp -p "$(source_index_path)" "$1" 2>/dev/null && add_to_index "$1" "$3" || return 1
  { cp -p "$(worktree_index_path)" "$1.tracked" 2>/dev/null && add_to_index "$1.tracked" "$3"; } || rm -f "$1.tracked"
  [ "$staging_mode" != all ] || git_on_index "$1" add -u || return 1
  case "$staging_mode" in only|include) ;; *) return 0 ;; esac
  (
    set -f; IFS='
'
    # shellcheck disable=SC2086
    [ "$staging_mode" != only ] || keep_only_named_entries "$1" $staged_paths || exit 1
    # shellcheck disable=SC2086
    git_on_index "$1" add -u -- $staged_paths
  )
}

keep_only_named_entries() {
  # $1 index file, then the paths the commit names. Resets that index to HEAD, keeping its entries
  # for those paths. Fails when git cannot.
  named_index="$1"; shift
  named_entries="$named_index.named"
  git_on_index "$named_index" ls-files -s --full-name -- "$@" >"$named_entries" || return 1
  head_tree=HEAD
  git_on_index "$named_index" rev-parse -q --verify HEAD >/dev/null || head_tree=--empty
  git_on_index "$named_index" read-tree "$head_tree" \
    && (GIT_INDEX_FILE="$named_index"; export GIT_INDEX_FILE
      cd "$standards_start_folder" && git update-index --index-info <"$named_entries" 2>/dev/null)
  named_status=$?
  rm -f "$named_entries"
  return "$named_status"
}

commit_index() {
  # $1 segment, $2 the shell command text it came from. Prints a throwaway index file that holds
  # what the commit will contain, or nothing when the command cannot be read.
  # discard_index_at_exit removes it.
  staging="$(commit_staging "$1")" || return 0
  adds="$(earlier_adds "$2")" || return 0
  index_folder="$(mktemp -d "${TMPDIR:-/tmp}/standards-index.XXXXXX" 2>/dev/null)" || return 0
  if write_commit_index "$index_folder/index" "$staging" "$adds"; then printf '%s' "$index_folder/index"; return 0; fi
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
  # $1 index file, or empty. Prints the commit's tree, the tree of the working files tracked on top
  # of it and the tree of the working files the worktree's index tracks, or nothing when git cannot
  # write one.
  [ -n "$1" ] || return 0
  commit_tree="$(git_on_index "$1" write-tree)" || return 0
  working_tree="$(working_files_tree "$1")" && tracked_tree="$(working_files_tree "$1.tracked")" || return 0
  printf '%s %s %s' "$commit_tree" "$working_tree" "$tracked_tree"
}

working_files_tree() {
  # $1 index file. Prints the tree of the working files that index tracks. Fails when git cannot.
  working_index="$1.working"
  cp -p "$1" "$working_index" 2>/dev/null && git_on_index "$working_index" add -u \
    && git_on_index "$working_index" write-tree
  working_status=$?
  rm -f "$working_index"
  return "$working_status"
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
    '$1 == check && ($2 " " $3 " " $4) == key && now - $5 <= window { seen = 1 } END { exit !seen }' "$(passed_file)" 2>/dev/null
}

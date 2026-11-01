#!/bin/sh
# W-01: block a commit whose subject is not a conventional commit, type(scope): summary. Git's own
# subjects (Merge, Revert, fixup!, squash!, amend!) pass. Called by the git commit-msg hook with
# the message file as $1, the only place the real message exists.
. "$(dirname "$0")/lib.sh"
[ -f "${1:-}" ] || exit 0
subject="$(grep -v '^#' "$1" | sed -n '/[^[:space:]]/{p;q;}')"
[ -n "$subject" ] || exit 0
case "$subject" in "Merge "*|"Revert "*|"fixup! "*|"squash! "*|"amend! "*) exit 0 ;; esac
types='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test'
printf '%s\n' "$subject" | grep -Eq "^($types)(\([^()[:space:]]+\))?!?: [^[:space:]]" && exit 0
block "the commit subject is not a conventional commit (W-01). Write type(scope): summary, with type one of ${types}. A gate's or an owner's instruction is not a subject." "  subject: $subject"

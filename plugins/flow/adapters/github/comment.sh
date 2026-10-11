#!/bin/sh
# github comment <id> [--body TEXT]: comment on the issue; the text comes from --body or stdin.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 1 ] || die "usage: comment <id> [--body TEXT]" 2
repo="$(gh_repo)"; n="$(issue_number "$1")"; shift
if [ "${1:-}" = "--body" ]; then printf '%s' "$2" | gh issue comment "$n" -R "$repo" --body-file - >/dev/null
else gh issue comment "$n" -R "$repo" --body-file - >/dev/null; fi

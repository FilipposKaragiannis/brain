#!/bin/sh
# github close <id> [--comment TEXT]: close the issue.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 1 ] || die "usage: close <id> [--comment TEXT]" 2
repo="$(gh_repo)"; n="$(issue_number "$1")"
if [ "${2:-}" = "--comment" ]; then gh issue close "$n" -R "$repo" --comment "$3" >/dev/null
else gh issue close "$n" -R "$repo" >/dev/null; fi

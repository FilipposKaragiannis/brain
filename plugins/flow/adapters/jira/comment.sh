#!/bin/sh
# jira comment <id> [--body TEXT]: comment on the issue; the text comes from --body or stdin.
. "$(dirname "$0")/_jira.sh"
[ $# -ge 1 ] || die "usage: comment <id> [--body TEXT]" 2
id="$1"; shift
if [ "${1:-}" = "--body" ]; then text="${2:-}"; else text="$(cat)"; fi
jira comment "$id" "$text"

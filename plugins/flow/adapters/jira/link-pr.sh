#!/bin/sh
# jira link-pr <id> <pr-url>: add the PR as a remote link on the issue and say it in a comment. It
# writes no state: the flow records the PR and its host (lib/pull_request.sh).
. "$(dirname "$0")/_jira.sh"
[ $# -ge 2 ] || die "usage: link-pr <id> <pr-url>" 2
jira remote-link "$1" "$2" || exit $?
jira comment "$1" "PR: $2"

#!/bin/sh
# jira link-pr <id> <pr-url>: record the PR in the state, with the host that wrote it (pr_host:
# claude or codex, the session this runs in), as a remote link on the issue and in a comment.
. "$(dirname "$0")/_jira.sh"
[ $# -ge 2 ] || die "usage: link-pr <id> <pr-url>" 2
author="$(host_name)"; case "$author" in claude|codex) ;; *) author="" ;; esac
"$FLOW_PLUGIN/adapters/jira/write-state.sh" "$1" "pr=$2" ${author:+"pr_host=$author"} || exit $?
jira remote-link "$1" "$2" || exit $?
jira comment "$1" "PR: $2"

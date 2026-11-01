#!/bin/sh
# github link-pr <id> <pr-url>: record the PR in the state and as a comment, with the host that
# wrote it (pr_host: claude or codex, the session this runs in). The PR body's "Resolves #n" line
# does the closing on merge.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 2 ] || die "usage: link-pr <id> <pr-url>" 2
author="$(host_name)"; case "$author" in claude|codex) ;; *) author="" ;; esac
"$FLOW_PLUGIN/adapters/github/write-state.sh" "$1" "pr=$2" ${author:+"pr_host=$author"}
"$FLOW_PLUGIN/adapters/github/comment.sh" "$1" --body "PR: $2"

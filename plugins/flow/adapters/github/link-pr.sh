#!/bin/sh
# github link-pr <id> <pr-url>: record the PR in the state and as a comment. The PR body's
# "Resolves #n" line does the closing on merge.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 2 ] || die "usage: link-pr <id> <pr-url>" 2
"$FLOW_PLUGIN/adapters/github/write-state.sh" "$1" "pr=$2"
"$FLOW_PLUGIN/adapters/github/comment.sh" "$1" --body "PR: $2"

#!/bin/sh
# github link-pr <id> <pr-url>: say the PR in a comment on the issue. It writes no state: the flow
# records the PR and its host (lib/pull_request.sh). The PR body's "Resolves #n" line does the
# closing on merge.
. "$(dirname "$0")/_gh.sh"
[ $# -ge 2 ] || die "usage: link-pr <id> <pr-url>" 2
"$FLOW_PLUGIN/adapters/github/comment.sh" "$1" --body "PR: $2"

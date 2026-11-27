#!/bin/sh
# pr-publish.sh open <reports> <base> <branch> <title> [--draft]: opens the pull request of the
# task branch, run from the claimed worktree (scripts/_pr_publish.py). It reads the body the
# pr-creator wrote to <reports>/pr-body.md, swaps in the Verification section pr-report.sh prints,
# writes the body back there and runs gh pr create with the body file and an --attach for each
# image and video under <reports>/evidence/, so each shows inline in the section. -R names
# github.repo from .flow/config.yaml when it is set. Every gh call that carries the body goes
# through here, never through the agent.
# Exit 0 with `created <url>` on stdout once the PR is created with every file attached; 1 with the
# reason on stderr when the report, the body or gh fails, and `created <url>` on stdout too when gh
# printed a PR; 2 on a usage error, a base or a branch that is no safe branch name included.
set -u
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/base.sh"
. "$FLOW_PLUGIN/lib/branch.sh"
USAGE="usage: pr-publish.sh open <reports> <base> <branch> <title> [--draft]"
[ $# -eq 5 ] || [ $# -eq 6 ] || die "$USAGE" 2
[ "$1" = open ] || die "$USAGE" 2
readiness=ready
if [ $# -eq 6 ]; then
  [ "$6" = --draft ] || die "$USAGE" 2
  readiness=draft
fi
branch_name_valid "$3" || die "the base is no safe branch name: $3" 2
branch_name_valid "$4" || die "the branch is no safe branch name: $4" 2
cached_python3 -I "$FLOW_PLUGIN/scripts/_pr_publish.py" open "$2" "$3" "$4" "$5" "$readiness" "$(cfg github.repo)"

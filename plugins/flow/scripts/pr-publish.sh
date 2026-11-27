#!/bin/sh
# pr-publish.sh open <reports> <base> <branch> <title> [--draft]: opens the pull request of the
# task branch, or updates the open one, run from the claimed worktree (scripts/_pr_publish.py). It
# looks up the open PR whose head is <branch> first. With none, it takes the body the pr-creator
# wrote to <reports>/pr-body.md and runs gh pr create; with one, it takes that PR's body and runs
# gh pr edit on it, so a retry after a partial upload updates the same PR. Either way it swaps in
# the Verification section pr-report.sh prints, writes the body to <reports>/pr-body.md and passes
# it with an --attach for each image and video under <reports>/evidence/, so each shows inline in
# the section. -R names github.repo from .flow/config.yaml when it is set. Every gh call that
# carries the body goes through here, never through the agent.
# Exit 0 with `created <url>` or `updated <url>` on stdout: the PR is made or changed and every file
# is attached. 1 with that line on stdout: the PR is made or changed, but some files are not
# attached; stderr quotes gh and names each with `not uploaded: <name>`, relative to evidence/: the
# one gh stopped at and every later one, an empty file, an image over 10 MiB or a video over
# 100 MiB. When gh uploaded nothing, the PR still gets the new section, its references left local
# until a retry. 1 with nothing on stdout: no PR was made or changed, because the report, the body,
# the lookup or gh failed first; stderr quotes why. 2: a usage error, a base or a branch that is no
# safe branch name included.
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

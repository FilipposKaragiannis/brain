#!/bin/sh
# pr-publish.sh open <reports> <base> <branch> <title> [--draft]: opens the pull request of the
# task branch, or updates the open one, run from the claimed worktree (scripts/_pr_publish.py). It
# looks up the open PR whose head is <branch> first. With none, it takes the body the pr-creator
# wrote to <reports>/pr-body.md and runs gh pr create; with one, it takes that PR's body and runs
# gh pr edit on it, so a retry after a partial upload updates the same PR. Either way it swaps in
# the Verification section pr-report.sh prints, writes the body to <reports>/pr-body.md and passes
# it with an --attach for each image and video under <reports>/evidence/, so each shows inline in
# the section. gh takes 50 files a call, so each later batch of 50 goes up with its own
# gh pr edit --attach, run in <reports> with no body flag. -R names github.repo from
# .flow/config.yaml when it is set. Every gh call that carries the body goes through here, never
# through the agent.
# Exit 0 with `created <url>` or `updated <url>` on stdout: the PR is made or changed and every file
# is attached. 1 with that line on stdout: the PR is made or changed, but some files are not
# attached; stderr quotes gh and names each with `not uploaded: <name>`, relative to evidence/: the
# one gh stopped at and every later one, in its batch and the batches after it, an empty file, an
# image over 10 MiB or a video over 100 MiB. When gh uploaded nothing, the PR still gets the new
# section, its references left local until a retry. 1 with nothing on stdout: no PR was made or changed, because the report, the body,
# the lookup or gh failed first; stderr quotes why. 2: a usage error, a base or a branch that is no
# safe branch name included.
# pr-publish.sh refresh <reports> <branch>: after a later verify, replaces the Verification section
# of the open PR whose head is <branch> with the new one and attaches its images and videos
# (scripts/_pr_refresh.py). It creates nothing, and every line outside the section stays as the PR
# holds it. It exits as open does, and also 1 with nothing on stdout when no open PR has that head,
# or when <reports>/verify.json was made at another commit than the worktree's HEAD, as pr-ready.sh
# refuses the pr step, with both commits on stderr.
set -u
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/base.sh"
. "$FLOW_PLUGIN/lib/branch.sh"
USAGE="usage: pr-publish.sh open <reports> <base> <branch> <title> [--draft], or refresh <reports> <branch>"
REFRESH_ARGUMENT_COUNT=3
if [ "${1:-}" = refresh ]; then
  [ $# -eq "$REFRESH_ARGUMENT_COUNT" ] || die "$USAGE" 2
  branch_name_valid "$3" || die "the branch is no safe branch name: $3" 2
  report="$2/verify.json"
  [ -f "$report" ] || die "no verify report at $report: run verify first"
  report_head="$(json_get "$(cat "$report")" head)"
  [ -n "$report_head" ] || die "the verify report names no commit: run verify again"
  worktree_head="$(git rev-parse HEAD)" || die "cannot read HEAD"
  case "$report_head" in
    *[!0-9a-f]*) report_commit="" ;;
    *) report_commit="$(git rev-parse --verify --quiet "$report_head^{commit}")" || report_commit="" ;;
  esac
  [ "$report_commit" = "$worktree_head" ] \
    || die "the verify report was made at $report_head, but HEAD is $worktree_head, so the pull request keeps its body: run verify again"
  cached_python3 -I "$FLOW_PLUGIN/scripts/_pr_refresh.py" "$2" "$3" "$(cfg github.repo)"
  exit
fi
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

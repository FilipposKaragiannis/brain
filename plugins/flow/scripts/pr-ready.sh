#!/bin/sh
# pr-ready.sh <item>: from the claimed worktree, says whether the pr step may open the PR. It
# refuses when <reports>/verify.json has no commit, when that commit (the full sha or the short one
# verify.sh writes) is not the worktree's HEAD, or when the worktree has changes outside .flow/, so
# a report made on an older commit or before an uncommitted change never passes. Exit 0 and nothing
# printed when the PR may open; exit 1 with the reason on stdout when it may not; exit 2 on a usage
# error. Never edits anything.
. "$(dirname "$0")/../lib/flow.sh"
[ $# -eq 1 ] || die "usage: pr-ready.sh <item>" 2
item="$1"
root="$(repo_root)" || die "not in a git repository"
cd "$root" || exit 1
reports="$(reports_dir "$item" "$root")"
report="$reports/verify.json"
[ -f "$report" ] || { echo "pr-ready: no verify report at $report: run verify first"; exit 1; }
report_head="$(json_get "$(cat "$report")" head)"
[ -n "$report_head" ] || { echo "pr-ready: the verify report names no commit: run verify again"; exit 1; }
worktree_head="$(git rev-parse HEAD)" || die "cannot read HEAD"
case "$report_head" in
  *[!0-9a-f]*) report_commit="" ;;
  *) report_commit="$(git rev-parse --verify --quiet "$report_head^{commit}")" || report_commit="" ;;
esac
if [ "$report_commit" != "$worktree_head" ]; then
  echo "pr-ready: the verify report was made at $report_head, but HEAD is $worktree_head: run verify again"
  exit 1
fi
outside_flow="$(git status --porcelain --untracked-files=all -- . ':(exclude).flow')" || die "cannot read the worktree status"
if [ -n "$outside_flow" ]; then
  echo "pr-ready: the worktree has changes outside .flow/, which the verify report at $report_head did not check: commit them and run verify again"
  printf '%s\n' "$outside_flow"
  exit 1
fi

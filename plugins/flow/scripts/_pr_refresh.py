"""Replaces the Verification section of the branch's open pull request after a later verify.
See scripts/pr-publish.sh, whose refresh checks first that verify.json was made at HEAD.

  _pr_refresh.py <reports dir> <branch> <repository or "">

The update path of scripts/_pr_publish.py open, with no create: it looks up the open pull request
whose head is <branch>, reads that PR's body, swaps in the section rendered from verify.json and
runs `gh pr edit <url>` with an `--attach` for each image and video under evidence/. Every line
outside the section stays as the PR holds it, so an owner's edit to the Summary is kept, and the
old section goes whole with the asset URLs it held. Exits as open does; with no open pull request
on <branch>, or a failed lookup, it exits 1 with no line on stdout and makes none.
"""
import os
import sys
from typing import List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pr_publish import (  # noqa: E402
    USAGE_EXIT,
    GhRunner,
    Outcome,
    PullRequestTarget,
    failed,
    open_pull_request_url,
    report_outcome,
    repository_arguments,
    run_gh,
    update_pull_request,
)
from _pr_report_input import read_report  # noqa: E402

REFRESH_ARGUMENT_COUNT = 3
NO_OPEN_PULL_REQUEST = "no open pull request has the head %s, so none is refreshed and none is made"
USAGE = "usage: _pr_refresh.py <reports dir> <branch> <repository>"


def refresh_pull_request(target: PullRequestTarget, gh: GhRunner) -> Outcome:
    report_read = read_report(target.reports)
    if report_read.problem:
        return failed(report_read.problem)
    lookup = open_pull_request_url(target, gh)
    if lookup.problem:
        return failed(lookup.problem)
    if not lookup.url:
        return failed(NO_OPEN_PULL_REQUEST % target.branch)
    return update_pull_request(target, report_read.report, lookup.url, gh)


def main(arguments: List[str]) -> int:
    if len(arguments) != REFRESH_ARGUMENT_COUNT:
        print(USAGE, file=sys.stderr)
        return USAGE_EXIT
    reports, branch, repository = arguments
    return report_outcome(refresh_pull_request(PullRequestTarget(reports, branch, repository_arguments(repository)), run_gh))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""Opens or updates the pull request with its Verification section and its images and videos.
See scripts/pr-publish.sh.

  _pr_publish.py open <reports dir> <base> <branch> <title> <draft|ready> <repository or "">

Looks up the open pull request whose head is <branch> first, and a failed lookup changes nothing.
Only a pull request from this repository counts: one from a fork whose branch has the same name, or
an entry gh lists without saying where it comes from, is never taken as the branch's. With none, it
reads the body the pr-creator wrote to <reports dir>/pr-body.md; with one, it reads that PR's body.
It swaps in the section scripts/_pr_report.py renders from verify.json (scripts/_pr_body.py),
writes the body to <reports dir>/pr-body.md and runs `gh pr create`, or `gh pr edit <url>`, with
`--body-file` on it and an `--attach` for each image and video under evidence/
(scripts/_pr_media.py) gh would take, by absolute path (scripts/_pr_attachments.py).
gh resolves each `./evidence/...` reference against the body file's folder, uploads the file and
puts its asset URL in the body. gh takes at most ATTACH_LIMIT files a call, so the first call
attaches that many and each later batch is a `gh pr edit <url> --attach ...` with no body flag, run
in <reports dir>: gh then rewrites the PR's own body against that folder, and a second body file
would put the local references back. A failed batch stops the rest. When the first call uploaded
nothing, gh made or changed no PR, so the same call runs again without `--attach`, and the PR holds
the new section with those references still local. A file not uploaded is the one gh stopped at
and every later one, in that batch and the batches after it.
Prints `created <url>` or `updated <url>` on stdout and exits 0 once every file is attached; exits
1 with that line, gh's error and a `not uploaded: <name>` line per file on stderr when the PR is
made or changed but some file is not attached; exits 1 with no line on stdout and the reason on
stderr when the report, the body, the lookup or gh fails before the PR is made or changed; exits 2
on a usage error. scripts/_pr_refresh.py runs the update path alone, after a later verify.
"""
import json
import os
import sys
from dataclasses import dataclass, replace
from enum import Enum
from typing import List, Mapping, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pr_attachments import Attachment, Attachments, attachments, not_uploaded  # noqa: E402
from _pr_body import read_body, replace_body, swapped_section  # noqa: E402
from _pr_gh import CURRENT_FOLDER, GH_SUCCEEDED_EXIT, GhResult, GhRunner, run_gh  # noqa: E402
from _pr_media import media_names  # noqa: E402
from _pr_report import LINE_BREAK, read_evidence, verification_section  # noqa: E402
from _pr_report_input import VerifyReport, read_report  # noqa: E402
from _verify_proofs import EVIDENCE_FOLDER  # noqa: E402

OPEN_COMMAND = "open"
OPEN_ARGUMENT_COUNT = 7
BODY_FILE_NAME = "pr-body.md"
REPOSITORY_OPTION = "-R"
# gh refuses a call with more --attach values than this, before it uploads anything.
ATTACH_LIMIT = 50
URL_PREFIXES = ("https://", "http://")
URL_FIELD = "url"
# A fork's pull request on a branch of the same name is an outsider's: gh's --head matches the name alone.
CROSS_REPOSITORY_FIELD = "isCrossRepository"
LISTED_FIELDS = "%s,%s" % (URL_FIELD, CROSS_REPOSITORY_FIELD)
CREATED_LINE = "created %s"
CREATE_COMMAND = "pr create"
EDIT_COMMAND = "pr edit"
GH_FAILED = "gh %s failed: %s"
GH_PRINTED_NO_URL = "gh %s printed no pull request URL"
LOOKUP_FAILED = "gh pr list --head %s --state open failed, so no pull request is made or changed: %s"
LOOKUP_AMBIGUOUS = "more than one open pull request from this repository has the head %s: %s"
BODY_FAILED = "gh pr view %s failed, so its body is left as it was: %s"
UPDATED_LINE = "updated %s"
NOT_UPLOADED = "not uploaded: %s"
PROBLEM_LINE = "flow: %s"
USAGE = "usage: _pr_publish.py open <reports dir> <base> <branch> <title> <draft|ready> <repository>"
PUBLISHED_EXIT = 0
FAILED_EXIT = 1
USAGE_EXIT = 2


class Readiness(Enum):
    DRAFT = "draft"
    READY = "ready"


READINESS_ARGUMENTS: Mapping[Readiness, Tuple[str, ...]] = {Readiness.DRAFT: ("--draft",), Readiness.READY: ()}


@dataclass(frozen=True)
class PullRequestTarget:
    reports: str
    branch: str
    repository_arguments: Tuple[str, ...]


@dataclass(frozen=True)
class OpenRequest:
    target: PullRequestTarget
    base: str
    title: str
    readiness: Readiness


@dataclass(frozen=True)
class Outcome:
    exit_code: int
    reported: Tuple[str, ...]
    problems: Tuple[str, ...]


@dataclass(frozen=True)
class Lookup:
    url: str
    problem: str


@dataclass(frozen=True)
class Publication:
    body: str
    arguments: Tuple[str, ...]
    command: str
    reported_line: str
    known_url: str


def body_file(reports: str) -> str:
    return os.path.abspath(os.path.join(reports, BODY_FILE_NAME))


def attachment_candidates(reports: str) -> Tuple[Attachment, ...]:
    return tuple(Attachment(name, os.path.abspath(os.path.join(reports, EVIDENCE_FOLDER, name))) for name in media_names(reports))


def attach_arguments(attached: Tuple[Attachment, ...]) -> List[str]:
    return [argument for attachment in attached for argument in ("--attach", attachment.path)]


def create_publication(request: OpenRequest, body_path: str, body: str) -> Publication:
    target = request.target
    return Publication(body, ("pr", "create", *target.repository_arguments, "--base", request.base, "--head", target.branch,
                        "--title", request.title, "--body-file", body_path, *READINESS_ARGUMENTS[request.readiness]),
                       CREATE_COMMAND, CREATED_LINE, "")


def edit_publication(target: PullRequestTarget, url: str, body_path: str, body: str) -> Publication:
    return Publication(body, ("pr", "edit", url, *target.repository_arguments, "--body-file", body_path),
                       EDIT_COMMAND, UPDATED_LINE, url)


def pull_request_url(stdout: str) -> str:
    urls = [line.strip() for line in stdout.split(LINE_BREAK) if line.strip().startswith(URL_PREFIXES)]
    return urls[-1] if urls else ""


def failed(problem: str) -> Outcome:
    return Outcome(FAILED_EXIT, (), (problem,))


def gh_failure(command: str, result: GhResult) -> str:
    return GH_FAILED % (command, result.stderr.strip())


def published(publication: Publication, url: str, reasons: Tuple[str, ...], missing: Tuple[Attachment, ...]) -> Outcome:
    if not url:
        return failed(GH_PRINTED_NO_URL % publication.command)
    names = tuple(NOT_UPLOADED % name for name in sorted(attachment.name for attachment in missing))
    exit_code = FAILED_EXIT if reasons or names else PUBLISHED_EXIT
    return Outcome(exit_code, (publication.reported_line % url,), (*reasons, *names))


def published_without_attachments(publication: Publication, attached: Attachments, upload: GhResult,
                                  gh: GhRunner) -> Outcome:
    result = gh(list(publication.arguments), CURRENT_FOLDER)
    if result.exit_code != GH_SUCCEEDED_EXIT:
        return failed(gh_failure(publication.command, result))
    url = pull_request_url(result.stdout) or publication.known_url
    return published(publication, url, (gh_failure(publication.command, upload),), attached.refused + attached.uploadable)


def published_in_batches(target: PullRequestTarget, publication: Publication, attached: Attachments, gh: GhRunner) -> Outcome:
    url = publication.known_url
    if not url:
        return failed(GH_PRINTED_NO_URL % publication.command)
    for batch_start in range(ATTACH_LIMIT, len(attached.uploadable), ATTACH_LIMIT):
        batch_end = batch_start + ATTACH_LIMIT
        batch = attached.uploadable[batch_start:batch_end]
        result = gh(["pr", "edit", url, *target.repository_arguments, *attach_arguments(batch)],
                    os.path.abspath(target.reports))
        if result.exit_code != GH_SUCCEEDED_EXIT:
            missing = (not_uploaded(batch, result.stderr) or batch) + attached.uploadable[batch_end:]
            return published(publication, url, (gh_failure(EDIT_COMMAND, result),), attached.refused + missing)
    return published(publication, url, (), attached.refused)


def publish(target: PullRequestTarget, publication: Publication, attached: Attachments, gh: GhRunner) -> Outcome:
    first_batch, later = attached.uploadable[:ATTACH_LIMIT], attached.uploadable[ATTACH_LIMIT:]
    result = gh([*publication.arguments, *attach_arguments(first_batch)], CURRENT_FOLDER)
    printed_url = pull_request_url(result.stdout)
    if result.exit_code == GH_SUCCEEDED_EXIT:
        return published_in_batches(target, replace(publication, known_url=printed_url or publication.known_url), attached, gh)
    missing = not_uploaded(first_batch, result.stderr)
    if printed_url:
        return published(publication, printed_url, (gh_failure(publication.command, result),),
                         attached.refused + (missing or first_batch) + later)
    if not missing:
        return failed(gh_failure(publication.command, result))
    return published_without_attachments(publication, attached, result, gh)


def publish_body(target: PullRequestTarget, report: VerifyReport, publication: Publication, gh: GhRunner) -> Outcome:
    section = verification_section(report, read_evidence(target.reports))
    problem = replace_body(body_file(target.reports), swapped_section(publication.body, section))
    if problem:
        return failed(problem)
    return publish(target, publication, attachments(attachment_candidates(target.reports)), gh)


def same_repository_urls(stdout: str) -> Optional[Tuple[str, ...]]:
    try:
        listed = json.loads(stdout)
    except ValueError:
        return None
    if not isinstance(listed, list) or not all(isinstance(entry, dict) and isinstance(entry.get(URL_FIELD), str) for entry in listed):
        return None
    return tuple(entry[URL_FIELD] for entry in listed if entry.get(CROSS_REPOSITORY_FIELD) is False)


def open_pull_request_url(target: PullRequestTarget, gh: GhRunner) -> Lookup:
    result = gh(["pr", "list", *target.repository_arguments, "--head", target.branch, "--state", "open", "--json", LISTED_FIELDS],
                CURRENT_FOLDER)
    urls = same_repository_urls(result.stdout) if result.exit_code == GH_SUCCEEDED_EXIT else None
    if urls is None:
        return Lookup("", LOOKUP_FAILED % (target.branch, result.stderr.strip() or result.stdout.strip()))
    if len(urls) > 1:
        return Lookup("", LOOKUP_AMBIGUOUS % (target.branch, " ".join(urls)))
    return Lookup(urls[0] if urls else "", "")


def create_pull_request(request: OpenRequest, report: VerifyReport, gh: GhRunner) -> Outcome:
    body_path = body_file(request.target.reports)
    body_read = read_body(body_path)
    if body_read.problem:
        return failed(body_read.problem)
    return publish_body(request.target, report, create_publication(request, body_path, body_read.body), gh)


def update_pull_request(target: PullRequestTarget, report: VerifyReport, url: str, gh: GhRunner) -> Outcome:
    result = gh(["pr", "view", url, *target.repository_arguments, "--json", "body", "-q", ".body"], CURRENT_FOLDER)
    if result.exit_code != GH_SUCCEEDED_EXIT:
        return failed(BODY_FAILED % (url, result.stderr.strip()))
    return publish_body(target, report, edit_publication(target, url, body_file(target.reports), result.stdout), gh)


def open_pull_request(request: OpenRequest, gh: GhRunner) -> Outcome:
    report_read = read_report(request.target.reports)
    if report_read.problem:
        return failed(report_read.problem)
    lookup = open_pull_request_url(request.target, gh)
    if lookup.problem:
        return failed(lookup.problem)
    if lookup.url:
        return update_pull_request(request.target, report_read.report, lookup.url, gh)
    return create_pull_request(request, report_read.report, gh)


def repository_arguments(repository: str) -> Tuple[str, ...]:
    return (REPOSITORY_OPTION, repository) if repository else ()


def parsed_request(arguments: List[str]) -> Optional[OpenRequest]:
    if len(arguments) != OPEN_ARGUMENT_COUNT:
        return None
    command, reports, base, branch, title, readiness_word, repository = arguments
    readiness_words = {readiness.value: readiness for readiness in Readiness}
    if command != OPEN_COMMAND or readiness_word not in readiness_words:
        return None
    return OpenRequest(target=PullRequestTarget(reports, branch, repository_arguments(repository)), base=base, title=title,
                       readiness=readiness_words[readiness_word])


def main(arguments: List[str]) -> int:
    request = parsed_request(arguments)
    if request is None:
        print(USAGE, file=sys.stderr)
        return USAGE_EXIT
    outcome = open_pull_request(request, run_gh)
    for line in outcome.reported:
        print(line)
    for problem in outcome.problems:
        print(PROBLEM_LINE % problem, file=sys.stderr)
    return outcome.exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

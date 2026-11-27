"""Opens the pull request with its Verification section and its images and videos. See
scripts/pr-publish.sh.

  _pr_publish.py open <reports dir> <base> <branch> <title> <draft|ready> <repository or "">

Reads the body the pr-creator wrote to <reports dir>/pr-body.md, swaps in the section
scripts/_pr_report.py renders from verify.json (swapped_section), writes the body back to that file
and runs one `gh pr create` with `--body-file` on it and an `--attach` for each image and video
under evidence/ (scripts/_pr_media.py), by absolute path. gh resolves each `./evidence/...`
reference against the body file's folder, uploads the file and puts its asset URL in the body.
The section runs from its heading to the next `## ` heading, the `Resolves #<n>` or `Item: <id>`
line or the end, and a line inside a fence never ends it, so an excerpt that holds such a line
stays inside. A body with no section gets it before that footer line, else at the end.
Prints `created <url>` on stdout and exits 0 once gh created the PR; exits 1 with the reason on
stderr when the report, the body or gh fails, with `created <url>` on stdout too when gh printed
one; exits 2 on a usage error.
"""
import os
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from enum import Enum
from typing import Callable, FrozenSet, List, Mapping, Optional, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pr_media import media_names  # noqa: E402
from _pr_report import LINE_BREAK, SECTION_HEADING, read_evidence, verification_section  # noqa: E402
from _pr_report_input import TEXT_ENCODING, read_report  # noqa: E402
from _verify_proofs import EVIDENCE_FOLDER  # noqa: E402

OPEN_COMMAND = "open"
OPEN_ARGUMENT_COUNT = 7
BODY_FILE_NAME = "pr-body.md"
GH_PROGRAM = "gh"
REPOSITORY_OPTION = "-R"
UNDECODABLE_BYTES = "replace"
# A video may be up to 100 MiB, and gh uploads every file before it returns.
GH_TIMEOUT_SECONDS = 1800
GH_SUCCEEDED_EXIT = 0
GH_NOT_RUN_EXIT = 127
HEADING_PREFIX = "## "
FOOTER_LINE = re.compile(r"(Resolves #\d+|Item: \S+)\s*$")
FENCE_OPENING = re.compile(r" {0,3}(`{3,}|~{3,})")
FENCE_CLOSING = r" {0,3}%s{%d,}\s*$"
URL_PREFIXES = ("https://", "http://")
CREATED_LINE = "created %s"
NO_BODY = "no pull request body at %s: %s"
UNWRITTEN_BODY = "cannot write the pull request body %s: %s"
GH_FAILED = "gh pr create failed: %s"
GH_PRINTED_NO_URL = "gh pr create printed no pull request URL"
GH_TIMED_OUT = "gh took longer than %d seconds"
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
class OpenRequest:
    reports: str
    base: str
    branch: str
    title: str
    readiness: Readiness
    repository_arguments: Tuple[str, ...]


@dataclass(frozen=True)
class GhResult:
    exit_code: int
    stdout: str
    stderr: str


@dataclass(frozen=True)
class Outcome:
    exit_code: int
    reported: Tuple[str, ...]
    problems: Tuple[str, ...]


@dataclass(frozen=True)
class BodyRead:
    body: str
    problem: str


@dataclass(frozen=True)
class SectionSpan:
    start: int
    end: int


GhRunner = Callable[[Sequence[str]], GhResult]


def run_gh(arguments: Sequence[str]) -> GhResult:
    try:
        completed = subprocess.run(  # noqa: S603 - an argument list and no shell
            [GH_PROGRAM, *arguments], capture_output=True, text=True, encoding=TEXT_ENCODING, errors=UNDECODABLE_BYTES,
            timeout=GH_TIMEOUT_SECONDS, check=False)
    except subprocess.TimeoutExpired:
        return GhResult(GH_NOT_RUN_EXIT, "", GH_TIMED_OUT % GH_TIMEOUT_SECONDS)
    except OSError as error:
        return GhResult(GH_NOT_RUN_EXIT, "", str(error))
    return GhResult(completed.returncode, completed.stdout, completed.stderr)


def fence_closes(line: str, opening: str) -> bool:
    return re.match(FENCE_CLOSING % (re.escape(opening[0]), len(opening)), line) is not None


def unfenced_positions(lines: List[str]) -> FrozenSet[int]:
    positions = set()
    opening = ""
    for position, line in enumerate(lines):
        if opening:
            opening = "" if fence_closes(line, opening) else opening
            continue
        fence = FENCE_OPENING.match(line)
        if fence:
            opening = fence.group(1)
            continue
        positions.add(position)
    return frozenset(positions)


def ends_section(line: str) -> bool:
    return line.startswith(HEADING_PREFIX) or FOOTER_LINE.match(line) is not None


def section_span(lines: List[str]) -> SectionSpan:
    open_positions = sorted(unfenced_positions(lines))
    start = next((position for position in open_positions if lines[position].rstrip() == SECTION_HEADING), None)
    if start is None:
        footer = next((position for position in open_positions if FOOTER_LINE.match(lines[position])), len(lines))
        return SectionSpan(footer, footer)
    end = next((position for position in open_positions if position > start and ends_section(lines[position])), len(lines))
    return SectionSpan(start, end)


def without_trailing_blank_lines(lines: List[str]) -> List[str]:
    kept = len(lines)
    while kept and not lines[kept - 1].strip():
        kept -= 1
    return lines[:kept]


def blank_line_beside(lines: List[str]) -> List[str]:
    return [""] if lines else []


def swapped_section(body: str, section: List[str]) -> str:
    lines = body.split(LINE_BREAK)
    span = section_span(lines)
    before = without_trailing_blank_lines(lines[:span.start])
    after = without_trailing_blank_lines(lines[span.end:])
    swapped = [*before, *blank_line_beside(before), *without_trailing_blank_lines(section), *blank_line_beside(after), *after]
    return LINE_BREAK.join(swapped) + LINE_BREAK


def read_body(path: str) -> BodyRead:
    try:
        with open(path, encoding=TEXT_ENCODING) as body_stream:
            return BodyRead(body_stream.read(), "")
    except (OSError, ValueError) as error:
        return BodyRead("", NO_BODY % (path, error))


def replace_body(path: str, body: str) -> str:
    folder, name = os.path.split(path)
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=".%s." % name, dir=folder)
    except OSError as error:
        return UNWRITTEN_BODY % (path, error)
    try:
        with os.fdopen(descriptor, "w", encoding=TEXT_ENCODING) as temporary_stream:
            temporary_stream.write(body)
        os.replace(temporary, path)
    except OSError as error:
        return UNWRITTEN_BODY % (path, error)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)
    return ""


def attachment_paths(reports: str) -> Tuple[str, ...]:
    return tuple(os.path.abspath(os.path.join(reports, EVIDENCE_FOLDER, name)) for name in media_names(reports))


def attach_arguments(attachments: Tuple[str, ...]) -> List[str]:
    return [argument for path in attachments for argument in ("--attach", path)]


def create_arguments(request: OpenRequest, body_path: str, attachments: Tuple[str, ...]) -> List[str]:
    return ["pr", "create", *request.repository_arguments, "--base", request.base, "--head", request.branch,
            "--title", request.title, "--body-file", body_path, *READINESS_ARGUMENTS[request.readiness],
            *attach_arguments(attachments)]


def pull_request_url(stdout: str) -> str:
    urls = [line.strip() for line in stdout.split(LINE_BREAK) if line.strip().startswith(URL_PREFIXES)]
    return urls[-1] if urls else ""


def created_outcome(result: GhResult) -> Outcome:
    url = pull_request_url(result.stdout)
    reported = (CREATED_LINE % url,) if url else ()
    if result.exit_code == GH_SUCCEEDED_EXIT and url:
        return Outcome(PUBLISHED_EXIT, reported, ())
    problem = GH_FAILED % result.stderr.strip() if result.exit_code != GH_SUCCEEDED_EXIT else GH_PRINTED_NO_URL
    return Outcome(FAILED_EXIT, reported, (problem,))


def failed(problem: str) -> Outcome:
    return Outcome(FAILED_EXIT, (), (problem,))


def write_body_with_section(reports: str, body_path: str) -> str:
    report_read = read_report(reports)
    if report_read.problem:
        return report_read.problem
    body_read = read_body(body_path)
    if body_read.problem:
        return body_read.problem
    section = verification_section(report_read.report, read_evidence(reports))
    return replace_body(body_path, swapped_section(body_read.body, section))


def open_pull_request(request: OpenRequest, gh: GhRunner) -> Outcome:
    body_path = os.path.abspath(os.path.join(request.reports, BODY_FILE_NAME))
    problem = write_body_with_section(request.reports, body_path)
    if problem:
        return failed(problem)
    return created_outcome(gh(create_arguments(request, body_path, attachment_paths(request.reports))))


def parsed_request(arguments: List[str]) -> Optional[OpenRequest]:
    if len(arguments) != OPEN_ARGUMENT_COUNT:
        return None
    command, reports, base, branch, title, readiness_word, repository = arguments
    readiness_words = {readiness.value: readiness for readiness in Readiness}
    if command != OPEN_COMMAND or readiness_word not in readiness_words:
        return None
    return OpenRequest(reports=reports, base=base, branch=branch, title=title, readiness=readiness_words[readiness_word],
                       repository_arguments=(REPOSITORY_OPTION, repository) if repository else ())


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

"""The Verification section of a pull request body, from the verify report. See scripts/pr-report.sh.

  _pr_report.py <reports dir>

Reads <reports dir>/verify.json alone, never verify.md, whose live proof links are relative to the
reports folder and resolve in no pull request. Prints the section as Markdown on stdout:

  ## Verification

  Verdict: <status> at <head>
  N of M acceptance lines proven live or by test

  | line | acceptance | grade | proof |
  |---|---|---|---|
  | <line> | <acceptance> | <grade> | <proof> |

  **Not checked**
  - Line <n>, <grade>: <reason>.

  <details>
  <summary><code><file></code>, last <kept> of <all> lines</summary>

  ````text
  <the file's last lines>
  ````
  </details>

  - `<file>`, kept in the reports folder.

The verdict line is verify.json's `verdict` as written. The table shows only when there are proofs.
A live proof names its file under evidence/ in a code span and links nothing: `|` escaped, and a
fence one backtick longer than any run in the name, for an HTML entity in a code span shows as
typed. Every other proof cell and the Not checked lines are verify's own
(scripts/_verify_report.py), so the list says `None.` when it is empty. The section has no other heading, so an update can swap it whole. Exits 1 with
the reason on stderr when the folder holds no readable verify.json object, or the report lacks a
key the section needs.

Every regular file under <reports dir>/evidence/, nested or not, that is not an image or a video
(MEDIA_EXTENSIONS) and decodes as UTF-8 with no NUL byte (is_text) gets a collapsed block, in name
order, because a reviewer reads the capture where they review: its last EXCERPT_LINES lines, each
without terminal colours, links or control characters but tab and cut to EXCERPT_LINE_CHARACTERS,
in a fence one backtick longer than any run in it and at least three, so the capture cannot close
it. The blocks as rendered, wrappers and line breaks included, share EXCERPT_BUDGET_CHARACTERS,
under GitHub's body limit; a file past it keeps its summary and says the excerpt was left out, and
once no summary fits either, one line counts the files left. A live proof of a file with a block
says the excerpt is below. Any other file is named as kept in the reports folder, and a media file shows only in its
proof cell. The walk follows no link and opens none, because the excerpt goes public.
"""
import html
import os
import posixpath
import re
import stat
import sys
from dataclasses import dataclass
from typing import FrozenSet, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _pr_report_input import TEXT_ENCODING, NotChecked, Proof, VerifyReport, read_report  # noqa: E402
from _verify_proofs import EVIDENCE_FOLDER, FILE_LINE, GRADE_ERROR, GRADE_LIVE, GRADE_TEST  # noqa: E402
from _verify_report import (  # noqa: E402
    COUNT_LINE,
    NOT_CHECKED_FILE,
    NOT_CHECKED_LINE,
    NOT_CHECKED_NONE,
    PROOFS_TABLE_HEAD,
    SEE_NOT_CHECKED,
    UNKNOWN_LINE,
    md_cell,
)
from _verify_text import one_line, terminal_free  # noqa: E402

SECTION_HEADING = "## Verification"
NOT_CHECKED_TITLE = "**Not checked**"
BACKTICK = "`"
BACKTICK_RUN = re.compile("`+")
CODE_SPAN_PADDING = " "
FENCE_LONGER_BY = 1
MEDIA_EXTENSIONS = frozenset((".png", ".jpg", ".jpeg", ".gif", ".webp", ".mp4", ".mov", ".webm"))
NULL_BYTE = b"\0"
SINGLE_LINE = 1
EXCERPT_LINES = 20
EXCERPT_LINE_CHARACTERS = 300
EXCERPT_BUDGET_CHARACTERS = 40000
MINIMUM_FENCE = 3
LINE_BREAK = "\n"
EXCERPT_LANGUAGE = "text"
DETAILS_OPEN = "<details>"
DETAILS_CLOSE = "</details>"
SUMMARY_LINE = "<summary><code>%s</code>, %s</summary>"
ONE_LINE = "1 line"
LINE_COUNT = "%d lines"
LAST_LINES = "last %d of %s"
PIPE = "|"
PIPE_ENTITY = "&#124;"
BODY_FULL = "excerpt left out: the body is full"
REST_LEFT_OUT = "Text captures left out, the body is full: %d"
EXCERPT_BELOW = ", excerpt below"
KEPT_LINE = "- %s, kept in the reports folder."
RENDERED_EXIT = 0
FAILED_EXIT = 1


@dataclass(frozen=True)
class TextEvidence:
    name: str
    line_count: int
    excerpt: Tuple[str, ...]


@dataclass(frozen=True)
class ExcerptSection:
    lines: Tuple[str, ...]
    shown_names: FrozenSet[str]


@dataclass(frozen=True)
class EvidenceFiles:
    excerpted: Tuple[TextEvidence, ...]
    kept: Tuple[str, ...]


def is_media(name: str) -> bool:
    return os.path.splitext(name)[1].lower() in MEDIA_EXTENSIONS


def is_text(raw: bytes) -> bool:
    if NULL_BYTE in raw:
        return False
    try:
        raw.decode(TEXT_ENCODING)
    except UnicodeDecodeError:
        return False
    return True


def is_regular_file(path: str) -> bool:
    try:
        return stat.S_ISREG(os.lstat(path).st_mode)
    except OSError:
        return False


def evidence_names(folder: str) -> List[str]:
    if os.path.islink(folder) or not os.path.isdir(folder):
        return []
    paths = [os.path.join(directory, file_name)
             for directory, _subfolders, file_names in os.walk(folder) for file_name in file_names]
    return sorted(os.path.relpath(path, folder).replace(os.sep, posixpath.sep) for path in paths if is_regular_file(path))


def file_bytes(path: str) -> Optional[bytes]:
    try:
        with open(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as evidence_stream:
            return evidence_stream.read()
    except OSError:
        return None


def file_lines(content: str) -> List[str]:
    lines = content.split(LINE_BREAK)
    return lines[:-1] if lines[-1] == "" else lines


def text_evidence(name: str, content: str) -> TextEvidence:
    lines = file_lines(content)
    excerpt = tuple(terminal_free(line)[:EXCERPT_LINE_CHARACTERS] for line in lines[-EXCERPT_LINES:])
    return TextEvidence(name=name, line_count=len(lines), excerpt=excerpt)


def read_evidence(reports: str) -> EvidenceFiles:
    folder = os.path.join(reports, EVIDENCE_FOLDER)
    names = [name for name in evidence_names(folder) if not is_media(name)]
    contents = {name: file_bytes(os.path.join(folder, name)) for name in names}
    excerpted = tuple(text_evidence(name, raw.decode(TEXT_ENCODING)) for name, raw in contents.items()
                      if raw is not None and is_text(raw))
    excerpted_names = {evidence.name for evidence in excerpted}
    return EvidenceFiles(excerpted=excerpted, kept=tuple(name for name in names if name not in excerpted_names))


def longest_backtick_run(value: str) -> int:
    return max((len(run) for run in BACKTICK_RUN.findall(value)), default=0)


def code_span(value: str) -> str:
    fence = BACKTICK * (longest_backtick_run(value) + FENCE_LONGER_BY)
    padding = CODE_SPAN_PADDING if value.startswith(BACKTICK) or value.endswith(BACKTICK) else ""
    return fence + padding + value + padding + fence


def shown_line(line: Optional[int]) -> str:
    return UNKNOWN_LINE if line is None else str(line)


def cell_span(value: str) -> str:
    return code_span(md_cell(value, None))


def proof_cell(proof: Proof, excerpted_names: FrozenSet[str]) -> str:
    if proof.grade == GRADE_LIVE:
        name = posixpath.relpath(proof.detail, EVIDENCE_FOLDER)
        return cell_span(name) + (EXCERPT_BELOW if name in excerpted_names else "")
    if proof.grade in (GRADE_TEST, GRADE_ERROR):
        return cell_span(proof.detail)
    return SEE_NOT_CHECKED


def proofs_table(proofs: Tuple[Proof, ...], excerpted_names: FrozenSet[str]) -> List[str]:
    if not proofs:
        return []
    rows = ["| %s | %s | %s | %s |" % (shown_line(proof.line), cell_span(proof.text), cell_span(proof.grade),
                                       proof_cell(proof, excerpted_names)) for proof in proofs]
    return [*PROOFS_TABLE_HEAD, *rows, ""]


def not_checked_line(entry: NotChecked) -> str:
    reason = code_span(one_line(entry.reason.rstrip(".")))
    if entry.line == FILE_LINE:
        return NOT_CHECKED_FILE % (code_span(one_line(entry.text)), code_span(one_line(entry.grade)), reason)
    return NOT_CHECKED_LINE % (shown_line(entry.line), code_span(one_line(entry.grade)), reason)


def not_checked_lines(not_checked: Tuple[NotChecked, ...]) -> List[str]:
    return [not_checked_line(entry) for entry in not_checked] or [NOT_CHECKED_NONE]


def line_count_text(count: int) -> str:
    return ONE_LINE if count == SINGLE_LINE else LINE_COUNT % count


def summary_line(evidence: TextEvidence) -> str:
    shown = len(evidence.excerpt)
    extent = line_count_text(shown) if shown == evidence.line_count else LAST_LINES % (shown, line_count_text(evidence.line_count))
    return SUMMARY_LINE % (html.escape(one_line(evidence.name)).replace(PIPE, PIPE_ENTITY), extent)


def rendered_characters(lines: List[str]) -> int:
    return sum(len(line) + len(LINE_BREAK) for line in lines)


def excerpt_block(evidence: TextEvidence) -> List[str]:
    fence = BACKTICK * max(MINIMUM_FENCE, max(map(longest_backtick_run, evidence.excerpt), default=0) + FENCE_LONGER_BY)
    return [DETAILS_OPEN, summary_line(evidence), "", fence + EXCERPT_LANGUAGE, *evidence.excerpt, fence, DETAILS_CLOSE]


def left_out_block(evidence: TextEvidence) -> List[str]:
    return [DETAILS_OPEN, summary_line(evidence), "", BODY_FULL, DETAILS_CLOSE]


def rest_left_out(count: int) -> List[str]:
    return ["", REST_LEFT_OUT % count] if count else []


def excerpt_section(excerpted: Tuple[TextEvidence, ...]) -> ExcerptSection:
    blocks: List[str] = []
    for position, evidence in enumerate(excerpted):
        after = len(excerpted) - position - 1
        room = EXCERPT_BUDGET_CHARACTERS - rendered_characters(blocks) - rendered_characters(rest_left_out(after))
        candidates = (["", *excerpt_block(evidence)], ["", *left_out_block(evidence)])
        fitting = next((block for block in candidates if rendered_characters(block) <= room), None)
        if fitting is None:
            return ExcerptSection(tuple(blocks + rest_left_out(after + 1)), frozenset(shown.name for shown in excerpted[:position]))
        blocks += fitting
    return ExcerptSection(tuple(blocks), frozenset(shown.name for shown in excerpted))


def kept_lines(kept: Tuple[str, ...]) -> List[str]:
    if not kept:
        return []
    return ["", *(KEPT_LINE % code_span(one_line(name)) for name in kept)]


def verification_section(report: VerifyReport, evidence: EvidenceFiles) -> List[str]:
    excerpts = excerpt_section(evidence.excerpted)
    return [SECTION_HEADING, "", report.verdict, COUNT_LINE % (report.proven, report.acceptance_lines), "",
            *proofs_table(report.proofs, excerpts.shown_names), NOT_CHECKED_TITLE, *not_checked_lines(report.not_checked),
            *excerpts.lines, *kept_lines(evidence.kept)]


def main(argv: List[str]) -> int:
    report_read = read_report(argv[0])
    if report_read.problem:
        print("flow: %s" % report_read.problem, file=sys.stderr)
        return FAILED_EXIT
    print("\n".join(verification_section(report_read.report, read_evidence(argv[0]))))
    return RENDERED_EXIT


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

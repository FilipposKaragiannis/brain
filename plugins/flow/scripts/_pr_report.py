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

The verdict line is verify.json's `verdict` as written. The table shows only when there are proofs.
A live proof names its file under evidence/ in a code span and links nothing: `|` escaped, and a
fence one backtick longer than any run in the name, for an HTML entity in a code span shows as
typed. Every other proof cell and the Not checked lines are verify's own
(scripts/_verify_report.py), so the list says `None.` when it is empty. The section has no other heading, so an update can swap it whole. Exits 1 with
the reason on stderr when the folder holds no readable verify.json object, or the report lacks a
key the section needs.
"""
import json
import os
import posixpath
import re
import sys
from dataclasses import dataclass
from typing import List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _verify_proofs import EVIDENCE_FOLDER, GRADE_LIVE  # noqa: E402
from _verify_report import (  # noqa: E402
    COUNT_LINE,
    PROOFS_TABLE_HEAD,
    md_cell,
    not_checked_lines,
    proof_cell,
    shown_line,
)

REPORT_FILE = "verify.json"
SECTION_HEADING = "## Verification"
NOT_CHECKED_TITLE = "**Not checked**"
REQUIRED_KEYS = ("verdict", "proven", "acceptance_lines", "proofs", "not_checked")
BACKTICK = "`"
BACKTICK_RUN = re.compile("`+")
CODE_SPAN_PADDING = " "
FENCE_LONGER_BY = 1
RENDERED_EXIT = 0
FAILED_EXIT = 1


@dataclass(frozen=True)
class VerifyReport:
    verdict: str
    proven: int
    acceptance_lines: int
    proofs: Tuple[dict, ...]
    not_checked: Tuple[dict, ...]


@dataclass(frozen=True)
class ReadReport:
    report: VerifyReport
    problem: str


EMPTY_REPORT = VerifyReport(verdict="", proven=0, acceptance_lines=0, proofs=(), not_checked=())


def read_report(reports: str) -> ReadReport:
    try:
        with open(os.path.join(reports, REPORT_FILE), encoding="utf-8") as report_stream:
            document = json.load(report_stream)
    except (OSError, ValueError, RecursionError) as error:
        return ReadReport(report=EMPTY_REPORT, problem="no verify report in %s: %s" % (reports, error))
    if not isinstance(document, dict):
        return ReadReport(report=EMPTY_REPORT, problem="no verify report in %s: %s is no JSON object" % (reports, REPORT_FILE))
    missing = [key for key in REQUIRED_KEYS if key not in document]
    if missing:
        return ReadReport(report=EMPTY_REPORT, problem="the verify report in %s has no `%s`" % (reports, missing[0]))
    return ReadReport(report=VerifyReport(verdict=document["verdict"], proven=document["proven"],
                                          acceptance_lines=document["acceptance_lines"],
                                          proofs=tuple(document["proofs"]), not_checked=tuple(document["not_checked"])),
                      problem="")


def code_span(value: str) -> str:
    fence = BACKTICK * (max((len(run) for run in BACKTICK_RUN.findall(value)), default=0) + FENCE_LONGER_BY)
    padding = CODE_SPAN_PADDING if value.startswith(BACKTICK) or value.endswith(BACKTICK) else ""
    return fence + padding + value + padding + fence


def live_proof_cell(entry: dict) -> str:
    return code_span(md_cell(posixpath.relpath(entry["evidence"], EVIDENCE_FOLDER), None))


def section_proof_cell(entry: dict) -> str:
    return live_proof_cell(entry) if entry["grade"] == GRADE_LIVE else proof_cell(entry)


def proofs_table(proofs: Tuple[dict, ...]) -> List[str]:
    if not proofs:
        return []
    rows = ["| %s | %s | %s | %s |" % (shown_line(entry), md_cell(entry["text"], None), entry["grade"],
                                       section_proof_cell(entry)) for entry in proofs]
    return [*PROOFS_TABLE_HEAD, *rows, ""]


def verification_section(report: VerifyReport) -> List[str]:
    return [SECTION_HEADING, "", report.verdict, COUNT_LINE % (report.proven, report.acceptance_lines), "",
            *proofs_table(report.proofs), NOT_CHECKED_TITLE, *not_checked_lines(list(report.not_checked))]


def main(argv: List[str]) -> int:
    report_read = read_report(argv[0])
    if report_read.problem:
        print("flow: %s" % report_read.problem, file=sys.stderr)
        return FAILED_EXIT
    print("\n".join(verification_section(report_read.report)))
    return RENDERED_EXIT


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

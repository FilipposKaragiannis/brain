"""The plan names the proof for each acceptance line the user sees, in a `## Acceptance` section of
plan.md in the reports folder, up to the next `## ` heading: the item's numbered line
(`2. <the line as written>`), then under it `Proof: <path> by <the test or replay that captures
it>`, the path relative to the reports folder and under `evidence/`. This module reads them for
scripts/_verify_proofs.py, which grades a named line live from its file. No plan.md, no such
section or no `Proof:` line in it names no proof. See scripts/_verify_report.py.

  _verify_plan_proofs.py check <reports>: the `plan proofs` check of scripts/verify.sh. No named
  proof: no output, exit 0. Every named file holds: one line naming them, exit 0. Else exit 1 with
  one line per problem, each naming the file and why (missing, empty, not a regular file, outside
  `evidence/`), or naming a plan line that is no line of proofs.json, or proofs.json when it
  cannot be read.
"""
import os
import re
import sys
from typing import List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _verify_proofs import (  # noqa: E402
    PLAN_FILE,
    PROOFS_FILE,
    NamedProof,
    given_text,
    is_acceptance_line,
    named_proof_problem,
    read_proofs,
    unmatched_line_problem,
)
from _verify_text import text  # noqa: E402

ACCEPTANCE_HEADING = "## Acceptance"
SECTION_HEADING_PREFIX = "## "
NUMBERED_LINE = re.compile(r"^(?P<line>\d+)\.\s")
PROOF_LINE = re.compile(r"^\s*Proof:\s*(?P<evidence>\S.*?) by (?P<capture>\S.*?)\s*$")
CHECK_COMMAND = "check"
CHECK_ARGUMENTS = 2
CHECK_PASSED_EXIT = 0
CHECK_FAILED_EXIT = 1
USAGE_EXIT = 2
USAGE = "usage: _verify_plan_proofs.py check <reports>"
HOLDING_FILES = "the named files hold: %s"
LINE_PROBLEM = "line %d: %s"
UNREADABLE_PROOFS_FILE = "%s cannot be graded: %s"
NAMED_FILE_SEPARATOR = ", "


def plan_lines(reports: str) -> List[str]:
    try:
        with open(os.path.join(reports, PLAN_FILE), "rb") as plan_stream:
            return text(plan_stream.read()).splitlines()
    except OSError:
        return []


def acceptance_section(lines: List[str]) -> List[str]:
    trimmed_lines = [line.rstrip() for line in lines]
    if ACCEPTANCE_HEADING not in trimmed_lines:
        return []
    after_heading = lines[trimmed_lines.index(ACCEPTANCE_HEADING) + 1:]
    section_end = next((position for position, line in enumerate(after_heading)
                        if line.startswith(SECTION_HEADING_PREFIX)), len(after_heading))
    return after_heading[:section_end]


def named_proofs(reports: str) -> Tuple[NamedProof, ...]:
    proofs = []
    acceptance_line = None
    for line in acceptance_section(plan_lines(reports)):
        numbered = NUMBERED_LINE.match(line)
        if numbered:
            acceptance_line = int(numbered.group("line"))
        proof = PROOF_LINE.match(line)
        if proof and acceptance_line is not None:
            proofs.append(NamedProof(line=acceptance_line, evidence=proof.group("evidence"),
                                     capture=proof.group("capture")))
    return tuple(proofs)


def evidence_problems(reports: str, proofs: Tuple[NamedProof, ...]) -> List[str]:
    problems = ((named.line, named_proof_problem(reports, named)) for named in proofs)
    return [LINE_PROBLEM % (line, problem) for line, problem in problems if problem]


def line_problems(reports: str, proofs: Tuple[NamedProof, ...]) -> List[str]:
    proofs_file = read_proofs(reports)
    if proofs_file.problem:
        return [UNREADABLE_PROOFS_FILE % (PROOFS_FILE, proofs_file.problem)]
    acceptance_lines = len(proofs_file.entries)
    return [unmatched_line_problem(named.line, acceptance_lines) for named in proofs
            if not is_acceptance_line(named.line, acceptance_lines)]


def main(arguments: List[str]) -> int:
    if len(arguments) != CHECK_ARGUMENTS or arguments[0] != CHECK_COMMAND:
        print(USAGE, file=sys.stderr)
        return USAGE_EXIT
    reports = arguments[1]
    proofs = named_proofs(reports)
    if not proofs:
        return CHECK_PASSED_EXIT
    problems = evidence_problems(reports, proofs) + line_problems(reports, proofs)
    if problems:
        print("\n".join(problems))
        return CHECK_FAILED_EXIT
    print(HOLDING_FILES % NAMED_FILE_SEPARATOR.join(given_text(named.evidence) for named in proofs))
    return CHECK_PASSED_EXIT


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

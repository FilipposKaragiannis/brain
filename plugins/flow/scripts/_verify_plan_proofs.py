"""The plan names the proof for each acceptance line the user sees, in a `## Acceptance` section of
plan.md in the reports folder, up to the next `## ` heading: the item's numbered line
(`2. <the line as written>`), then under it `Proof: <path> by <the test or replay that captures
it>`, the path relative to the reports folder and under `evidence/`. This module reads them for
scripts/_verify_proofs.py, which grades a named line live from its file. No plan.md, no such
section or no `Proof:` line in it names no proof, and a `Proof:` line outside the section is not
read. A `Proof:` line in it is malformed when it has no path or no ` by <capture>`, comes before
any numbered line, is a second one for the same line, or names a path that is absolute, goes
through `..` or is not under `evidence/`. A line with a malformed path still names its proof, so
the report grades the line error; any other malformed line names none, and of two proofs for one
line the first is named. See scripts/_verify_report.py.

  _verify_plan_proofs.py check <reports>: the `plan proofs` check of scripts/verify.sh. No named
  proof and no malformed line: no output, exit 0. Every named file holds: one line naming them,
  exit 0. Else exit 1 with one line per problem: a malformed line, naming its line in plan.md; a
  named file that does not hold, naming the file and why (missing, empty, not a regular file,
  outside `evidence/`); a plan line that is no line of proofs.json; or proofs.json when it cannot
  be read.
"""
import os
import posixpath
import re
import sys
from dataclasses import dataclass
from typing import AbstractSet, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _verify_proofs import (  # noqa: E402
    EVIDENCE_FOLDER,
    NULL_CHARACTER,
    OUTSIDE_EVIDENCE,
    PARENT_FOLDER,
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
PROOF_PREFIX = re.compile(r"^\s*Proof:")
FIRST_PLAN_LINE = 1
EVIDENCE_PREFIX = EVIDENCE_FOLDER + "/"
PATH_SEPARATOR = "/"
PLAN_LINE_PROBLEM = "%s line %d: %s"
PROOF_LABEL = "Proof:"
NO_PATH_OR_CAPTURE = "%s names no path or no ` by <capture>`"
BEFORE_ANY_NUMBERED_LINE = "%s comes before any numbered line"
SECOND_PROOF = "%s is a second proof for line %d"
MALFORMED_PATH = "%s names %s, which %s"
ABSOLUTE_PATH = "is absolute"
THROUGH_PARENT_FOLDER = "goes through %s" % PARENT_FOLDER
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


@dataclass(frozen=True)
class PlanLine:
    number: int
    text: str


@dataclass(frozen=True)
class PlanProofs:
    proofs: Tuple[NamedProof, ...]
    problems: Tuple[str, ...]


def plan_lines(reports: str) -> List[PlanLine]:
    try:
        with open(os.path.join(reports, PLAN_FILE), "rb") as plan_stream:
            plan_text = text(plan_stream.read())
    except OSError:
        return []
    return [PlanLine(number=number, text=line)
            for number, line in enumerate(plan_text.splitlines(), FIRST_PLAN_LINE)]


def acceptance_section(lines: List[PlanLine]) -> List[PlanLine]:
    trimmed_lines = [line.text.rstrip() for line in lines]
    if ACCEPTANCE_HEADING not in trimmed_lines:
        return []
    after_heading = lines[trimmed_lines.index(ACCEPTANCE_HEADING) + 1:]
    section_end = next((position for position, line in enumerate(after_heading)
                        if line.text.startswith(SECTION_HEADING_PREFIX)), len(after_heading))
    return after_heading[:section_end]


def placement_problem(proof_text: str, acceptance_line: Optional[int], named_lines: AbstractSet[int]) -> str:
    shown = given_text(proof_text.strip())
    if not PROOF_LINE.match(proof_text):
        return NO_PATH_OR_CAPTURE % shown
    if acceptance_line is None:
        return BEFORE_ANY_NUMBERED_LINE % shown
    return SECOND_PROOF % (shown, acceptance_line) if acceptance_line in named_lines else ""


def evidence_path_problem(evidence: str) -> str:
    if os.path.isabs(evidence):
        return ABSOLUTE_PATH
    if PARENT_FOLDER in evidence.split(PATH_SEPARATOR):
        return THROUGH_PARENT_FOLDER
    inside = posixpath.normpath(evidence).startswith(EVIDENCE_PREFIX)
    return "" if inside and NULL_CHARACTER not in evidence else OUTSIDE_EVIDENCE


def malformed_path_problems(plan_line: PlanLine, named: NamedProof) -> List[str]:
    path_problem = evidence_path_problem(named.evidence)
    if not path_problem:
        return []
    return [PLAN_LINE_PROBLEM % (PLAN_FILE, plan_line.number,
                                 MALFORMED_PATH % (PROOF_LABEL, given_text(named.evidence), path_problem))]


def plan_proofs(reports: str) -> PlanProofs:
    proofs: List[NamedProof] = []
    problems: List[str] = []
    acceptance_line = None
    for plan_line in acceptance_section(plan_lines(reports)):
        numbered = NUMBERED_LINE.match(plan_line.text)
        if numbered:
            acceptance_line = int(numbered.group("line"))
        if not PROOF_PREFIX.match(plan_line.text):
            continue
        placement = placement_problem(plan_line.text, acceptance_line, {named.line for named in proofs})
        if placement:
            problems.append(PLAN_LINE_PROBLEM % (PLAN_FILE, plan_line.number, placement))
            continue
        proof = PROOF_LINE.match(plan_line.text)
        named = NamedProof(line=acceptance_line, evidence=proof.group("evidence"), capture=proof.group("capture"))
        proofs.append(named)
        problems += malformed_path_problems(plan_line, named)
    return PlanProofs(proofs=tuple(proofs), problems=tuple(problems))


def named_proofs(reports: str) -> Tuple[NamedProof, ...]:
    return plan_proofs(reports).proofs


def evidence_problems(reports: str, proofs: Tuple[NamedProof, ...]) -> List[str]:
    problems = ((named.line, named_proof_problem(reports, named)) for named in proofs
                if not evidence_path_problem(named.evidence))
    return [LINE_PROBLEM % (line, problem) for line, problem in problems if problem]


def line_problems(reports: str, proofs: Tuple[NamedProof, ...]) -> List[str]:
    if not proofs:
        return []
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
    plan = plan_proofs(reports)
    if not plan.proofs and not plan.problems:
        return CHECK_PASSED_EXIT
    problems = [*plan.problems, *evidence_problems(reports, plan.proofs), *line_problems(reports, plan.proofs)]
    if problems:
        print("\n".join(problems))
        return CHECK_FAILED_EXIT
    print(HOLDING_FILES % NAMED_FILE_SEPARATOR.join(given_text(named.evidence) for named in plan.proofs))
    return CHECK_PASSED_EXIT


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

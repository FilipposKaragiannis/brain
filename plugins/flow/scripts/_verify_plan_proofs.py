"""The plan names the proof for each acceptance line the user sees, in a `## Acceptance` section of
plan.md in the reports folder, up to the next `## ` heading: the item's numbered line
(`2. <the line as written>`), then under it `Proof: <path> by <the test or replay that captures
it>`, the path relative to the reports folder and under `evidence/`. This module reads them for
scripts/_verify_proofs.py, which grades a named line live from its file. No plan.md, no such
section or no `Proof:` line in it names no proof. See scripts/_verify_report.py.
"""
import os
import re
import sys
from typing import List, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _verify_proofs import NamedProof  # noqa: E402
from _verify_text import text  # noqa: E402

PLAN_FILE = "plan.md"
ACCEPTANCE_HEADING = "## Acceptance"
SECTION_HEADING_PREFIX = "## "
NUMBERED_LINE = re.compile(r"^(?P<line>\d+)\.\s")
PROOF_LINE = re.compile(r"^\s*Proof:\s*(?P<evidence>\S.*?) by (?P<capture>\S.*?)\s*$")


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

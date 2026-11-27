"""The verifier writes proofs.json in the reports folder before the run: {"head": <the commit it
graded>, "proofs": [{"line", "text", "grade", and `evidence` for live, `test` and `check` for test
or `reason` for build-only and blocked}]}, one entry per acceptance line. This module grades
it. A proof that does not hold becomes {"line", "text", "grade": "error", "claimed", "reason"}:
a grade that is not live, test, build-only or blocked; a line that is not a whole number from 1
to M (M being the entries in the file) or that two entries share; live whose `evidence`, links
followed, is no regular file under `evidence/` in the reports folder; test with no name, or whose
check did not pass in this run, reused passes included: `check` names a tests check (`tests` or
`tests <name>`), and may be left out only when the run has exactly one; build-only or blocked with
no reason; any entry of a file written for another head. No proofs file is no proofs; a file that
is no JSON object with a `proofs` list is one Not checked entry with line 0 and the file's name. A
line the plan names (scripts/_verify_plan_proofs.py) wins over the verifier's entry for any head:
when its file holds, by the rule for live and not empty, {"line", "text", "grade": "live",
"evidence": <the plan's path>, "capture": <what captures it>}, the text kept from proofs.json;
else {"line", "text", "grade": "error", "claimed": "live", "reason"} naming the file. A named line
graded twice is graded as any other; one that is no line of proofs.json is one Not checked entry
with line 0 and plan.md. A named proof can fail the run, through the `plan proofs` check of
scripts/verify.sh; every other proof never changes the status. See scripts/_verify_report.py.
"""
import json
import os
import sys
from collections import Counter
from dataclasses import dataclass
from types import MappingProxyType
from typing import Callable, FrozenSet, List, Mapping, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _verify_text import one_line, text  # noqa: E402

PROOFS_FILE = "proofs.json"
PLAN_FILE = "plan.md"
EVIDENCE_FOLDER = "evidence"
PARENT_FOLDER = ".."
NULL_CHARACTER = "\0"
GRADE_LIVE = "live"
GRADE_TEST = "test"
GRADE_BUILD_ONLY = "build-only"
GRADE_BLOCKED = "blocked"
GRADE_ERROR = "error"
PROVEN_GRADES = frozenset((GRADE_LIVE, GRADE_TEST))
FIRST_LINE = 1
ONCE = 1
SINGLE_TESTS_CHECK = 1
FILE_LINE = 0
NO_HEAD = "no commit"
GIVEN_VALUE_MAX = 80
PASSED = "pass"
TEST_CHECK = "tests"
OUTSIDE_EVIDENCE = "is outside %s/" % EVIDENCE_FOLDER
MISSING = "is missing"
NOT_A_REGULAR_FILE = "is not a regular file"
EMPTY = "is empty"
EMPTY_SIZE = 0
NAMED_FILE_PROBLEM = "%s names %s, which %s"
UNMATCHED_NAMED_LINE = "%s names line %d, which is not a line of %s (%d to %d)"


@dataclass(frozen=True)
class ProofsFile:
    entries: Tuple[object, ...]
    written_for: str
    problem: str


@dataclass(frozen=True)
class Proof:
    line: Optional[int]
    given_line: str
    text: str
    grade: str
    evidence: str
    test: str
    check: str
    reason: str


@dataclass(frozen=True)
class NamedProof:
    line: int
    evidence: str
    capture: str


@dataclass(frozen=True)
class GradingContext:
    reports: str
    test_checks: Tuple[str, ...]
    passed_test_checks: FrozenSet[str]
    acceptance_lines: int
    repeated_lines: FrozenSet[int]
    head_problem: str
    named_proofs: Mapping[int, NamedProof]


def encodable(value: str) -> str:
    return value.encode("utf-8", errors="replace").decode("utf-8")


def given_text(value: object) -> str:
    return one_line(encodable(value) if isinstance(value, str) else json.dumps(value))[:GIVEN_VALUE_MAX]


def read_proofs(reports: str) -> ProofsFile:
    try:
        with open(os.path.join(reports, PROOFS_FILE), "rb") as proofs_stream:
            document = json.loads(text(proofs_stream.read()))
    except FileNotFoundError:
        return ProofsFile(entries=(), written_for="", problem="")
    except (OSError, ValueError, RecursionError) as error:
        return ProofsFile(entries=(), written_for="", problem="it could not be read as JSON: %s" % one_line(str(error)))
    if not isinstance(document, dict) or not isinstance(document.get("proofs"), list):
        return ProofsFile(entries=(), written_for="", problem="it is not an object with a proofs list")
    head = document.get("head")
    return ProofsFile(entries=tuple(document["proofs"]), written_for=head if isinstance(head, str) else "", problem="")


def string_field(fields: Mapping[str, object], key: str) -> str:
    value = fields.get(key)
    return encodable(value) if isinstance(value, str) else ""


def parsed_proof(entry: object) -> Proof:
    fields = entry if isinstance(entry, dict) else {}
    line = fields.get("line")
    whole = isinstance(line, int) and not isinstance(line, bool)
    return Proof(line=line if whole else None, given_line=given_text(line), text=one_line(string_field(fields, "text")),
                 grade=given_text(fields.get("grade")), evidence=string_field(fields, "evidence"),
                 test=string_field(fields, "test"), check=one_line(string_field(fields, "check")),
                 reason=one_line(string_field(fields, "reason")))


def captured_file_problem(reports: str, evidence: str) -> str:
    if NULL_CHARACTER in evidence or os.path.isabs(evidence) or PARENT_FOLDER in evidence.split("/"):
        return OUTSIDE_EVIDENCE
    evidence_folder = os.path.join(os.path.realpath(reports), EVIDENCE_FOLDER)
    real_path = os.path.realpath(os.path.join(reports, evidence))
    if os.path.commonpath([real_path, evidence_folder]) != evidence_folder:
        return OUTSIDE_EVIDENCE
    if not os.path.exists(real_path):
        return MISSING
    return "" if os.path.isfile(real_path) else NOT_A_REGULAR_FILE


def is_captured_file(reports: str, evidence: str) -> bool:
    return not captured_file_problem(reports, evidence)


def named_file_problem(reports: str, evidence: str) -> str:
    problem = captured_file_problem(reports, evidence)
    if problem:
        return problem
    return EMPTY if os.path.getsize(os.path.join(reports, evidence)) == EMPTY_SIZE else ""


def named_proof_problem(reports: str, named: NamedProof) -> str:
    problem = named_file_problem(reports, named.evidence)
    return NAMED_FILE_PROBLEM % (PLAN_FILE, given_text(named.evidence), problem) if problem else ""


def is_acceptance_line(line: int, acceptance_lines: int) -> bool:
    return FIRST_LINE <= line <= acceptance_lines


def unmatched_line_problem(line: int, acceptance_lines: int) -> str:
    return UNMATCHED_NAMED_LINE % (PLAN_FILE, line, PROOFS_FILE, FIRST_LINE, acceptance_lines)


def captured_file(evidence: str, context: GradingContext) -> bool:
    return is_captured_file(context.reports, evidence)


def live_problem(proof: Proof, context: GradingContext) -> str:
    if not proof.evidence.strip():
        return "graded live, but it names no evidence file"
    return "" if captured_file(proof.evidence, context) else "graded live, but %s is no captured file" % given_text(proof.evidence)


def test_problem(proof: Proof, context: GradingContext) -> str:
    if not proof.test.strip():
        return "graded test, but it names no test"
    return check_problem(owning_check(proof, context), context)


def owning_check(proof: Proof, context: GradingContext) -> str:
    if proof.check or len(context.test_checks) != SINGLE_TESTS_CHECK:
        return proof.check
    return context.test_checks[0]


def check_problem(check: str, context: GradingContext) -> str:
    if not check:
        return "graded test, but it names no check, and this run has %d tests checks" % len(context.test_checks)
    if check not in context.test_checks:
        return "graded test, but %s is no tests check of this run" % given_text(check)
    return "" if check in context.passed_test_checks else "graded test, but %s did not pass in this run" % check


def reason_problem(proof: Proof, context: GradingContext) -> str:
    return "" if proof.reason else "graded %s, but it gives no reason" % proof.grade


GRADE_RULES: Mapping[str, Callable[[Proof, GradingContext], str]] = MappingProxyType({
    GRADE_LIVE: live_problem,
    GRADE_TEST: test_problem,
    GRADE_BUILD_ONLY: reason_problem,
    GRADE_BLOCKED: reason_problem,
})


def line_in_range(proof: Proof, context: GradingContext) -> bool:
    return proof.line is not None and FIRST_LINE <= proof.line <= context.acceptance_lines


def line_problem(proof: Proof, context: GradingContext) -> str:
    if not line_in_range(proof, context):
        return "line %s is not a whole number from %d to %d" % (proof.given_line, FIRST_LINE, context.acceptance_lines)
    return "line %d is graded more than once" % proof.line if proof.line in context.repeated_lines else ""


def proof_problem(proof: Proof, context: GradingContext) -> str:
    if context.head_problem:
        return context.head_problem
    if proof.grade not in GRADE_RULES:
        return "the grade %s is not live, test, build-only or blocked" % proof.grade
    return line_problem(proof, context) or GRADE_RULES[proof.grade](proof, context)


def named_entry(proof: Proof, context: GradingContext) -> Optional[dict]:
    named = context.named_proofs.get(proof.line)
    if named is None or not line_in_range(proof, context) or proof.line in context.repeated_lines:
        return None
    problem = named_proof_problem(context.reports, named)
    if problem:
        return {"line": proof.line, "text": proof.text, "grade": GRADE_ERROR, "claimed": GRADE_LIVE, "reason": problem}
    return {"line": proof.line, "text": proof.text, "grade": GRADE_LIVE, "evidence": named.evidence,
            "capture": named.capture}


def graded_entry(proof: Proof, context: GradingContext) -> dict:
    named = named_entry(proof, context)
    if named is not None:
        return named
    line = proof.line if line_in_range(proof, context) else None
    problem = proof_problem(proof, context)
    if problem:
        return {"line": line, "text": proof.text, "grade": GRADE_ERROR, "claimed": proof.grade, "reason": problem}
    grade_details = {GRADE_LIVE: {"evidence": proof.evidence},
                     GRADE_TEST: {"test": proof.test, "check": owning_check(proof, context)}}
    return {"line": line, "text": proof.text, "grade": proof.grade, **grade_details.get(proof.grade, {"reason": proof.reason})}


def head_problem(written_for: str, head: str) -> str:
    return "" if written_for == head else "written for %s, not the commit this run checked" % (given_text(written_for) or NO_HEAD)


def is_test_check(check: dict) -> bool:
    return check["name"] == TEST_CHECK or check["name"].startswith(TEST_CHECK + " ")


def unreadable_proofs(reason: str) -> dict:
    return {"proven": 0, "acceptance_lines": 0, "proofs": [],
            "not_checked": [{"line": FILE_LINE, "text": PROOFS_FILE, "grade": GRADE_ERROR, "reason": reason}]}


def unmatched_named_proofs(named_proofs: Tuple[NamedProof, ...], acceptance_lines: int) -> List[dict]:
    return [{"line": FILE_LINE, "text": PLAN_FILE, "grade": GRADE_ERROR,
             "reason": unmatched_line_problem(named.line, acceptance_lines)}
            for named in named_proofs if not is_acceptance_line(named.line, acceptance_lines)]


def repeated_lines(proofs: List[Proof]) -> FrozenSet[int]:
    line_counts = Counter(proof.line for proof in proofs if proof.line is not None)
    return frozenset(line for line, count in line_counts.items() if count > ONCE)


def graded(reports: str, head: str, report_checks: List[dict], named_proofs: Tuple[NamedProof, ...]) -> dict:
    proofs_file = read_proofs(reports)
    if proofs_file.problem:
        return unreadable_proofs(proofs_file.problem)
    proofs = [parsed_proof(entry) for entry in proofs_file.entries]
    test_checks = [check for check in report_checks if is_test_check(check)]
    context = GradingContext(reports=reports, test_checks=tuple(check["name"] for check in test_checks),
                             passed_test_checks=frozenset(check["name"] for check in test_checks
                                                          if check["status"] == PASSED),
                             acceptance_lines=len(proofs),
                             repeated_lines=repeated_lines(proofs),
                             head_problem=head_problem(proofs_file.written_for, head),
                             named_proofs=MappingProxyType({named.line: named for named in named_proofs}))
    entries = [graded_entry(proof, context) for proof in proofs]
    return {"proven": sum(entry["grade"] in PROVEN_GRADES for entry in entries), "acceptance_lines": len(entries),
            "proofs": entries,
            "not_checked": [{key: entry[key] for key in ("line", "text", "grade", "reason")}
                            for entry in entries if entry["grade"] not in PROVEN_GRADES]
            + unmatched_named_proofs(named_proofs, len(entries))}


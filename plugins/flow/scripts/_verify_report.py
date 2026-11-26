"""The verify report, built from data. See scripts/verify.sh.

  _verify_report.py <records> <changed> <reports dir> <status> <attempts> <base> <merge base>
                    <head> <feel_test true|false|not_ruled_out> <log> [<timings> <total seconds>]

<records> holds one check after another as four NUL-terminated fields: name, status, command and
the summary source (the command's whole output for a failed check, a fixed sentence otherwise).
<changed> holds the changed files, each followed by U+001F. <timings> holds one line per check,
in the same order: the whole seconds the check ran, a tab, and the run a reused pass came from
(empty for a check that ran). Each check then carries `seconds`, a reused one `reused_from`, and the report
the run's total `seconds`; a line that is missing or no number counts as 0. Bytes that are not
UTF-8 are replaced, never fatal. The summary is the last five non-empty lines of its source on one line, without control
characters, terminal colours or terminal hyperlinks (OSC 8: the target goes and the link's text
stays; one cut short with no terminator goes to the end), cut to 400 characters. <head> is the
full commit the run checked.

The verifier writes proofs.json in the reports folder before the run: {"head": <the commit it
graded>, "proofs": [{"line", "text", "grade", and `evidence` for live, `test` and `check` for test
or `reason` for build-only and blocked}]}, one entry per acceptance line. The builder grades it
here. A proof that does not hold becomes {"line", "text", "grade": "error", "claimed", "reason"}:
a grade that is not live, test, build-only or blocked; a line that is not a whole number from 1
to M (M being the entries in the file) or that two entries share; live whose `evidence`, links
followed, is no regular file under `evidence/` in the reports folder; test with no name, or whose
check did not pass in this run, reused passes included: `check` names a tests check (`tests` or
`tests <name>`), and may be left out only when the run has exactly one; build-only or blocked with
no reason; any entry of a file written for another head. No proofs file is no proofs; a file that
is no JSON object with a `proofs` list is one Not checked entry with line 0 and the file's name. A proof never
changes the status.

verify.json holds `proven` (the lines graded live or test that hold), `acceptance_lines` (M),
`proofs` and `not_checked` ({"line", "text", "grade", "reason"} for each line graded build-only,
blocked or error). verify.md opens with the verdict line, `Verdict: <status> at <head>`, which
verify.json holds as `verdict`; then `N of M acceptance lines proven live or by test`; then a
`## Proofs` table when there are proofs; then the checks, then a `## Not checked` section, which
lists `- Line <n>, <grade>: <reason>.` or says none when empty. Writes verify.json and verify.md
through a temp file and a rename each, so a reader sees the old report or the new one, never a part.
"""
import json
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass
from types import MappingProxyType
from typing import Callable, FrozenSet, List, Mapping, Optional, Tuple

SUMMARY_MAX = 400
MD_SUMMARY_MAX = 200
SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
ARGUMENTS_WITHOUT_TIMINGS = 10
NAME_SEPARATOR = "\x1f"
VERDICT_LINE = "Verdict: %s at %s"
NOT_CHECKED_HEADING = "## Not checked"
NOT_CHECKED_NONE = "None."
PROOFS_FILE = "proofs.json"
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
UNKNOWN_LINE = "?"
NO_HEAD = "no commit"
GIVEN_VALUE_MAX = 80
PASSED = "pass"
TEST_CHECK = "tests"
COUNT_LINE = "%d of %d acceptance lines proven live or by test"
PROOFS_HEADING = "## Proofs"
PROOFS_TABLE_HEAD = ("| line | acceptance | grade | proof |", "|---|---|---|---|")
SEE_NOT_CHECKED = "see Not checked"
NOT_CHECKED_LINE = "- Line %s, %s: %s."
NOT_CHECKED_FILE = "- %s, %s: %s."
FEEL_TEST_REASONS = MappingProxyType({
    "true": "a changed file matches `feel_test_paths`",
    "not_ruled_out": "verify could not list every changed file, so a change under `feel_test_paths` cannot be ruled out",
})
_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
_OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\|$)")
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def text(raw):
    return raw.decode("utf-8", errors="replace")


def one_line(s):
    return " ".join(_CONTROL.sub(" ", _ANSI.sub("", _OSC.sub("", s))).split())


def summary(source):
    lines = [l for l in source.splitlines() if l.strip()][-5:]
    return one_line(" ".join(lines))[:SUMMARY_MAX]


def checks(records):
    fields = records.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % 4:
        raise ValueError("the check records are cut short: %d fields, not a multiple of 4" % len(fields))
    out = []
    for i in range(0, len(fields), 4):
        name, status, command, source = (text(f) for f in fields[i:i + 4])
        out.append({"name": one_line(name), "status": status, "command": command, "summary": summary(source)})
    return out


def whole_seconds(raw):
    return int(raw) if raw.strip().isdigit() else 0


def timed(report_checks, timings):
    lines = timings.split("\n")
    for position, check in enumerate(report_checks):
        seconds, _, reused_from = (lines[position] if position < len(lines) else "").partition("\t")
        check["seconds"] = whole_seconds(seconds)
        if reused_from.strip():
            check["reused_from"] = one_line(reused_from)
    return report_checks


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
class GradingContext:
    reports: str
    evidence_folder: str
    test_checks: Tuple[str, ...]
    passed_test_checks: FrozenSet[str]
    acceptance_lines: int
    repeated_lines: FrozenSet[int]
    head_problem: str


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


def captured_file(evidence: str, context: GradingContext) -> bool:
    if NULL_CHARACTER in evidence or os.path.isabs(evidence) or PARENT_FOLDER in evidence.split("/"):
        return False
    real_path = os.path.realpath(os.path.join(context.reports, evidence))
    inside = os.path.commonpath([real_path, context.evidence_folder]) == context.evidence_folder
    return inside and os.path.isfile(real_path)


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


def graded_entry(proof: Proof, context: GradingContext) -> dict:
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


def graded(reports: str, head: str, report_checks: List[dict]) -> dict:
    proofs_file = read_proofs(reports)
    if proofs_file.problem:
        return unreadable_proofs(proofs_file.problem)
    proofs = [parsed_proof(entry) for entry in proofs_file.entries]
    line_counts = Counter(proof.line for proof in proofs if proof.line is not None)
    test_checks = [check for check in report_checks if is_test_check(check)]
    context = GradingContext(reports=reports, evidence_folder=os.path.join(os.path.realpath(reports), EVIDENCE_FOLDER),
                             test_checks=tuple(check["name"] for check in test_checks),
                             passed_test_checks=frozenset(check["name"] for check in test_checks
                                                          if check["status"] == PASSED),
                             acceptance_lines=len(proofs),
                             repeated_lines=frozenset(line for line, count in line_counts.items() if count > ONCE),
                             head_problem=head_problem(proofs_file.written_for, head))
    entries = [graded_entry(proof, context) for proof in proofs]
    return {"proven": sum(entry["grade"] in PROVEN_GRADES for entry in entries), "acceptance_lines": len(entries),
            "proofs": entries,
            "not_checked": [{key: entry[key] for key in ("line", "text", "grade", "reason")}
                            for entry in entries if entry["grade"] not in PROVEN_GRADES]}


def duration(seconds):
    if seconds < SECONDS_PER_MINUTE:
        return "%ds" % seconds
    if seconds < SECONDS_PER_HOUR:
        return "%dm %02ds" % (seconds // SECONDS_PER_MINUTE, seconds % SECONDS_PER_MINUTE)
    return "%dh %02dm" % (seconds // SECONDS_PER_HOUR, seconds % SECONDS_PER_HOUR // SECONDS_PER_MINUTE)


def write_atomic(path, content):
    tmp = "%s/.%s.%d.tmp" % (os.path.dirname(path), os.path.basename(path), os.getpid())
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


def md_cell(s, limit=None):
    s = one_line(s)
    return (s[:limit] if limit else s).replace("|", "\\|")


def shown_line(entry: dict) -> str:
    return str(entry["line"]) if entry["line"] is not None else UNKNOWN_LINE


PROOF_CELLS: Mapping[str, Callable[[dict], str]] = MappingProxyType({
    GRADE_LIVE: lambda entry: "[%s](<%s>)" % (md_cell(entry["evidence"], None), md_cell(entry["evidence"], None)),
    GRADE_TEST: lambda entry: "`%s`" % md_cell(entry["test"], None),
    GRADE_ERROR: lambda entry: md_cell(entry["reason"], None),
})


def proof_cell(entry: dict) -> str:
    cell = PROOF_CELLS.get(entry["grade"])
    return cell(entry) if cell is not None else SEE_NOT_CHECKED


def proofs_section(proofs: List[dict]) -> List[str]:
    if not proofs:
        return []
    rows = ["| %s | %s | %s | %s |" % (shown_line(entry), md_cell(entry["text"], None), entry["grade"],
                                       proof_cell(entry)) for entry in proofs]
    return [PROOFS_HEADING, "", *PROOFS_TABLE_HEAD, *rows, ""]


def not_checked_line(entry: dict) -> str:
    reason = entry["reason"].rstrip(".")
    if entry["line"] == FILE_LINE:
        return NOT_CHECKED_FILE % (entry["text"], entry["grade"], reason)
    return NOT_CHECKED_LINE % (shown_line(entry), entry["grade"], reason)


def not_checked_lines(not_checked: List[dict]) -> List[str]:
    return [not_checked_line(entry) for entry in not_checked] or [NOT_CHECKED_NONE]


def main(argv):
    records, changed, reports, status, attempts, base, merge_base, head, feel, log = argv[:ARGUMENTS_WITHOUT_TIMINGS]
    has_timings = len(argv) > ARGUMENTS_WITHOUT_TIMINGS
    with open(records, "rb") as f:
        report_checks = checks(f.read())
    if has_timings:
        with open(argv[ARGUMENTS_WITHOUT_TIMINGS], "rb") as f:
            report_checks = timed(report_checks, text(f.read()))
    with open(changed, "rb") as f:
        files = [name for name in text(f.read()).split(NAME_SEPARATOR) if name]
    verdict = VERDICT_LINE % (status, head)
    graded_proofs = graded(reports, head, report_checks)
    report = {
        "status": status,
        "verdict": verdict,
        "checks": report_checks,
        "attempts": int(attempts),
        "base": base,
        "head": head,
        "changed_files": files,
        "feel_test": feel in FEEL_TEST_REASONS,
        "proven": graded_proofs["proven"],
        "acceptance_lines": graded_proofs["acceptance_lines"],
        "proofs": graded_proofs["proofs"],
        "not_checked": graded_proofs["not_checked"],
    }
    md = [verdict, COUNT_LINE % (graded_proofs["proven"], graded_proofs["acceptance_lines"]), ""]
    md += proofs_section(graded_proofs["proofs"])
    md += ["## Checks (attempt %s)" % attempts, ""]
    if has_timings:
        report["seconds"] = whole_seconds(argv[ARGUMENTS_WITHOUT_TIMINGS + 1])
        md += ["| check | status | time | summary |", "|---|---|---|---|"]
        md += ["| %s | %s | %s | %s |" % (md_cell(c["name"]), md_cell(c["status"]), duration(c["seconds"]), md_cell(c["summary"], MD_SUMMARY_MAX)) for c in report_checks]
        md += ["", "The run took %s." % duration(report["seconds"])]
    else:
        md += ["| check | status | summary |", "|---|---|---|"]
        md += ["| %s | %s | %s |" % (md_cell(c["name"]), md_cell(c["status"]), md_cell(c["summary"], MD_SUMMARY_MAX)) for c in report_checks]
    md += ["", "Base `%s` (%s), head `%s`, %d changed files. Log: `%s`." % (base, merge_base, head, len(files), log)]
    if report["feel_test"]:
        md.append("**Feel-test needed:** %s." % FEEL_TEST_REASONS[feel])
    md += ["", NOT_CHECKED_HEADING, "", *not_checked_lines(graded_proofs["not_checked"])]
    write_atomic(os.path.join(reports, "verify.json"), json.dumps(report, indent=2) + "\n")
    write_atomic(os.path.join(reports, "verify.md"), "\n".join(md) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])

"""The verify report, built from data. See scripts/verify.sh.

  _verify_report.py <records> <changed> <reports dir> <status> <attempts> <base> <merge base>
                    <head> <feel_test true|false|not_ruled_out> <log> [<timings> <total seconds>
                    [<summary patterns>]]

<records> holds one check after another as four NUL-terminated fields: name, status, command and
the summary source (the output of a check that ran, a fixed sentence otherwise). <summary patterns>
holds a check name and its `summary` pattern, a Python regular expression, as two NUL-terminated
fields per check that has one.
<changed> holds the changed files, each followed by U+001F. <timings> holds one line per check,
in the same order: the whole seconds the check ran, a tab, and the run a reused pass came from
(empty for a check that ran). Each check then carries `seconds`, a reused one `reused_from`, and the report
the run's total `seconds`; a line that is missing or no number counts as 0. Bytes that are not
UTF-8 are replaced, never fatal. A failed check's summary is the last five non-empty lines of
its source on one line, as the stop gate and the escalation message read it; any other check's is
one line of its source: the last line its pattern matches, else the last non-empty line, else
`ok`. A pattern that is no regular expression says so as the summary. Either is without control
characters, terminal colours or terminal hyperlinks (OSC 8: the target goes and the link's text
stays; one cut short with no terminator goes to the end), cut to 400 characters. <head> is the
full commit the run checked.

The verifier's proofs.json in the reports folder is graded by scripts/_verify_proofs.py.

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
from types import MappingProxyType
from typing import Callable, List, Mapping

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _verify_proofs import FILE_LINE, GRADE_ERROR, GRADE_LIVE, GRADE_TEST, graded  # noqa: E402
from _verify_text import one_line, text  # noqa: E402

SUMMARY_MAX = 400
MD_SUMMARY_MAX = 200
SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
ARGUMENTS_WITHOUT_TIMINGS = 10
ARGUMENTS_WITHOUT_SUMMARY_PATTERNS = 12
FAILED = "fail"
SUMMARY_WITHOUT_OUTPUT = "ok"
FIELDS_PER_SUMMARY_PATTERN = 2
NAME_SEPARATOR = "\x1f"
VERDICT_LINE = "Verdict: %s at %s"
NOT_CHECKED_HEADING = "## Not checked"
NOT_CHECKED_NONE = "None."
UNKNOWN_LINE = "?"
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


def summary(source):
    lines = [l for l in source.splitlines() if l.strip()][-5:]
    return one_line(" ".join(lines))[:SUMMARY_MAX]


def summary_line(source: str, pattern: str) -> str:
    lines = [cleaned for cleaned in (one_line(line) for line in source.splitlines()) if cleaned]
    if pattern:
        try:
            wanted = re.compile(pattern)
        except re.error as problem:
            return one_line("the summary pattern %s is not a regular expression: %s" % (pattern, problem))[:SUMMARY_MAX]
        lines = [line for line in lines if wanted.search(line)] or lines
    return (lines or [SUMMARY_WITHOUT_OUTPUT])[-1][:SUMMARY_MAX]


def check_summary(status: str, source: str, pattern: str) -> str:
    if status == FAILED:
        return summary(source)
    return summary_line(source, pattern)


def summary_patterns(raw: bytes) -> dict:
    fields = [text(field) for field in raw.split(b"\0")][:-1]
    return dict(zip(fields[0::FIELDS_PER_SUMMARY_PATTERN], fields[1::FIELDS_PER_SUMMARY_PATTERN]))


def checks(records: bytes, patterns: dict) -> list:
    fields = records.split(b"\0")
    if fields and fields[-1] == b"":
        fields.pop()
    if len(fields) % 4:
        raise ValueError("the check records are cut short: %d fields, not a multiple of 4" % len(fields))
    out = []
    for i in range(0, len(fields), 4):
        name, status, command, source = (text(f) for f in fields[i:i + 4])
        out.append({"name": one_line(name), "status": status, "command": command, "summary": check_summary(status, source, patterns.get(name, ""))})
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
    patterns = {}
    if len(argv) > ARGUMENTS_WITHOUT_SUMMARY_PATTERNS:
        with open(argv[ARGUMENTS_WITHOUT_SUMMARY_PATTERNS], "rb") as patterns_file:
            patterns = summary_patterns(patterns_file.read())
    with open(records, "rb") as records_file:
        report_checks = checks(records_file.read(), patterns)
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

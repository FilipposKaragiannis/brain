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
full commit the run checked. verify.md opens with the verdict line, `Verdict: <status> at <head>`,
which verify.json holds as `verdict`; then the checks, then a `## Not checked` section, which says
none when empty. verify.json holds `proofs` and `not_checked` as lists, empty until a run fills
them; an evidence file a proof names lives under `evidence/` in the reports folder. Writes
verify.json and verify.md through a temp file and a rename each, so a reader sees the old report
or the new one, never a part.
"""
import json
import os
import re
import sys
from types import MappingProxyType

SUMMARY_MAX = 400
MD_SUMMARY_MAX = 200
SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
ARGUMENTS_WITHOUT_TIMINGS = 10
NAME_SEPARATOR = "\x1f"
VERDICT_LINE = "Verdict: %s at %s"
NOT_CHECKED_HEADING = "## Not checked"
NOT_CHECKED_NONE = "None."
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
    report = {
        "status": status,
        "verdict": verdict,
        "checks": report_checks,
        "attempts": int(attempts),
        "base": base,
        "head": head,
        "changed_files": files,
        "feel_test": feel in FEEL_TEST_REASONS,
        "proofs": [],
        "not_checked": [],
    }
    md = [verdict, "", "## Checks (attempt %s)" % attempts, ""]
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
    md += ["", NOT_CHECKED_HEADING, "", NOT_CHECKED_NONE]
    write_atomic(os.path.join(reports, "verify.json"), json.dumps(report, indent=2) + "\n")
    write_atomic(os.path.join(reports, "verify.md"), "\n".join(md) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])

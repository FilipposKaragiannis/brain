"""The verify report, built from data. See scripts/verify.sh.

  _verify_report.py <records> <changed> <reports dir> <status> <attempts> <base> <merge base>
                    <head> <feel_test true|false> <log>

<records> holds one check after another as four NUL-terminated fields: name, status, command and
the summary source (the command's whole output for a failed check, a fixed sentence otherwise).
<changed> holds the changed files, one per line. Bytes that are not UTF-8 are replaced, never
fatal. The summary is the last five non-empty lines of its source on one line, without control
characters, terminal colours or terminal hyperlinks (OSC 8: the target goes and the link's text
stays; one cut short with no terminator goes to the end), cut to 400 characters. Writes
verify.json and verify.md through a temp file and a rename each, so a reader sees the old report
or the new one, never a part.
"""
import json
import os
import re
import sys

SUMMARY_MAX = 400
MD_SUMMARY_MAX = 200
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
    records, changed, reports, status, attempts, base, merge_base, head, feel, log = argv
    with open(records, "rb") as f:
        cs = checks(f.read())
    with open(changed, "rb") as f:
        files = [l for l in text(f.read()).split("\n") if l.strip()]
    report = {
        "status": status,
        "checks": cs,
        "attempts": int(attempts),
        "base": base,
        "head": head,
        "changed_files": files,
        "feel_test": feel == "true",
    }
    md = ["## Verify: %s (attempt %s)" % (status, attempts), "",
          "| check | status | summary |", "|---|---|---|"]
    md += ["| %s | %s | %s |" % (md_cell(c["name"]), md_cell(c["status"]), md_cell(c["summary"], MD_SUMMARY_MAX)) for c in cs]
    md += ["", "Base `%s` (%s), head `%s`, %d changed files. Log: `%s`." % (base, merge_base, head, len(files), log)]
    if report["feel_test"]:
        md.append("**Feel-test needed:** a changed file matches `feel_test_paths`.")
    write_atomic(os.path.join(reports, "verify.json"), json.dumps(report, indent=2) + "\n")
    write_atomic(os.path.join(reports, "verify.md"), "\n".join(md) + "\n")


if __name__ == "__main__":
    main(sys.argv[1:])

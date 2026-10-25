"""Pending gates as JSON. See gate.sh list --json.

  _gates.py <now iso>

Reads one gate record per line on stdin (the record in <flow home>/gates/ plus its claimed
worktree) and prints one JSON array, oldest first. Each gate carries its age against <now> and
its questions: a line starting with a number and a dot or bracket opens a question. "Recommended:"
(any case, the colon required, markdown marks such as ** or - allowed before it) starts the
recommended answer, on the numbered line itself or on a following line, and the lines after it
continue the answer until the next numbered line. Any other line joins the question's text. A
message with no numbered line has no questions; the reader then shows the message itself."""
import calendar, json, re, sys, time

QUESTION = re.compile(r"^\s*(\d+)[.)](?:\s+|$)(.*)$")
MARKS = r"[*_]*"
RECOMMENDED_LINE = re.compile(r"^[\s*_-]*recommended%s:%s\s*(.*)$" % (MARKS, MARKS), re.IGNORECASE)
RECOMMENDED_INLINE = re.compile(r"\s[*_]*recommended%s:%s\s*" % (MARKS, MARKS), re.IGNORECASE)


def epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None


def text(value):
    return "" if value is None else str(value)


def joined(before, line):
    return (before + " " + line.strip()).strip()


def opened(number, body):
    inline = RECOMMENDED_INLINE.search(" " + body)
    if inline is None:
        return {"number": number, "text": body.strip(), "recommended": None}
    cut = inline.start() - 1
    return {"number": number, "text": body[:max(cut, 0)].strip(), "recommended": body[cut + len(inline.group(0)):].strip()}


def questions(message):
    found = []
    for line in message.splitlines():
        start = QUESTION.match(line)
        if start:
            found.append(opened(int(start.group(1)), start.group(2)))
            continue
        if not found or not line.strip():
            continue
        current = found[-1]
        if current["recommended"] is not None:
            current["recommended"] = joined(current["recommended"], line)
            continue
        recommended = RECOMMENDED_LINE.match(line)
        if recommended:
            current["recommended"] = recommended.group(1).strip()
            continue
        current["text"] = joined(current["text"], line)
    return found


def gate(record, now):
    message, when = text(record.get("message")), text(record.get("time"))
    then = epoch(when)
    return {
        "item": record.get("item"),
        "gate": record.get("gate"),
        "message": message,
        "time": when,
        "host": record.get("host"),
        "worktree": record.get("worktree"),
        "age_seconds": None if then is None or now is None else max(0, now - then),
        "questions": questions(message),
    }


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: _gates.py <now iso>")
    now = epoch(sys.argv[1])
    lines = sys.stdin.buffer.read().decode("utf-8").splitlines()
    records = [json.loads(line) for line in lines if line.strip()]
    gates = sorted((gate(r, now) for r in records), key=lambda g: g["time"])
    print(json.dumps(gates, indent=2))


main()

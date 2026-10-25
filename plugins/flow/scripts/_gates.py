"""Pending gates as JSON. See gate.sh list --json.

  _gates.py <now iso>

Reads one gate record per line on stdin (the record in <flow home>/gates/ plus its claimed
worktree) and prints one JSON array, oldest first. Each gate carries its age against <now> and
its questions: a line starting with a number and a dot or bracket opens a question, a following
line starting with "Recommended" (any case, colon optional) is its recommended answer, any other
line joins the question's text. A message with no numbered line has no questions."""
import calendar, json, re, sys, time

QUESTION = re.compile(r"^\s*(\d+)[.)](?:\s+|$)(.*)$")
RECOMMENDED = re.compile(r"^\s*recommended\b:?\s*(.*)$", re.IGNORECASE)


def epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None


def questions(message):
    found = []
    for line in (message or "").splitlines():
        opened = QUESTION.match(line)
        if opened:
            found.append({"number": int(opened.group(1)), "text": opened.group(2).strip(), "recommended": None})
            continue
        if not found or not line.strip():
            continue
        current = found[-1]
        recommended = RECOMMENDED.match(line)
        if recommended and current["recommended"] is None:
            current["recommended"] = recommended.group(1).strip()
            continue
        current["text"] = (current["text"] + " " + line.strip()).strip()
    return found


def gate(record, now):
    then = epoch(record.get("time"))
    return {
        "item": record.get("item"),
        "gate": record.get("gate"),
        "message": record.get("message"),
        "time": record.get("time"),
        "host": record.get("host"),
        "worktree": record.get("worktree"),
        "age_seconds": None if then is None or now is None else max(0, now - then),
        "questions": questions(record.get("message")),
    }


def main():
    now = epoch(sys.argv[1])
    records = [json.loads(line) for line in sys.stdin if line.strip()]
    gates = sorted((gate(r, now) for r in records), key=lambda g: g["time"] or "")
    print(json.dumps(gates, indent=2))


main()

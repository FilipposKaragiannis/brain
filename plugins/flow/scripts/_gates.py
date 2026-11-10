"""Pending gates as JSON. See gate.sh list --json.

  _gates.py <now iso>
  _gates.py options <json>

Reads one gate record per line on stdin (the record in <flow home>/gates/ plus its claimed
worktree) and prints one JSON array, oldest first. Each gate carries its age against <now> and
its questions: a line starting with a number and a dot or bracket opens a question. "Recommended:"
(any case, the colon required, markdown marks such as ** or - allowed before it) starts the
recommended answer, on the numbered line itself or on a following line, and the lines after it
continue the answer until the next numbered line. Any other line joins the question's text. A
message with no numbered line has no questions; the reader then shows the message itself. After
those come the record's options ([] when it has none or they do not validate), raised_by,
answered_by, condition and footer (null when absent), so a record from before them still lists.

The options mode validates the options gate.sh raise was given: 1 to 9 objects, each with a
non-empty label and text and a true or false recommended (false when absent), at most one
recommended. It prints them normalised (trimmed, other keys dropped), or exits non-zero with the
reason."""
import calendar, json, re, sys, time

QUESTION = re.compile(r"^\s*(\d+)[.)](?:\s+|$)(.*)$")
MARKS = r"[*_]*"
RECOMMENDED_LINE = re.compile(r"^[\s*_-]*recommended%s:%s\s*(.*)$" % (MARKS, MARKS), re.IGNORECASE)
RECOMMENDED_INLINE = re.compile(r"\s[*_]*recommended%s:%s\s*" % (MARKS, MARKS), re.IGNORECASE)
FEWEST_OPTIONS, MOST_OPTIONS = 1, 9


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


def option_problem(entry, position):
    if not isinstance(entry, dict):
        return "option %d is not an object" % position
    for key in ("label", "text"):
        value = entry.get(key)
        if not isinstance(value, str) or not value.strip():
            return "option %d has no %s" % (position, key)
    if not isinstance(entry.get("recommended", False), bool):
        return "option %d: recommended is not true or false" % position
    return None


def options_problem(value):
    if not isinstance(value, list) or not FEWEST_OPTIONS <= len(value) <= MOST_OPTIONS:
        return "options are not an array of %d to %d objects" % (FEWEST_OPTIONS, MOST_OPTIONS)
    for position, entry in enumerate(value, 1):
        problem = option_problem(entry, position)
        if problem:
            return problem
    if sum(1 for entry in value if entry.get("recommended", False)) > 1:
        return "more than one option is recommended"
    return None


def normalised_options(value):
    return [
        {"label": entry["label"].strip(), "text": entry["text"].strip(), "recommended": entry.get("recommended", False)}
        for entry in value
    ]


def recorded_options(value):
    return [] if options_problem(value) else normalised_options(value)


def optional_text(value):
    return value if isinstance(value, str) and value else None


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
        "options": recorded_options(record.get("options")),
        "raised_by": optional_text(record.get("raised_by")),
        "answered_by": optional_text(record.get("answered_by")),
        "condition": optional_text(record.get("condition")),
        "footer": optional_text(record.get("footer")),
    }


def print_options(source):
    try:
        value = json.loads(source)
    except ValueError:
        sys.exit("options are not JSON")
    problem = options_problem(value)
    if problem:
        sys.exit(problem)
    print(json.dumps(normalised_options(value)))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "options":
        print_options(sys.argv[2])
        return
    if len(sys.argv) != 2:
        sys.exit("usage: _gates.py <now iso> | _gates.py options <json>")
    now = epoch(sys.argv[1])
    lines = sys.stdin.buffer.read().decode("utf-8").splitlines()
    records = [json.loads(line) for line in lines if line.strip()]
    gates = sorted((gate(r, now) for r in records), key=lambda g: g["time"])
    print(json.dumps(gates, indent=2))


main()

"""Notes file plumbing for the intake job. See jobs/intake.sh.

  _intake.py parse <notes> <ledger> <batch>                    the next unfiled notes, as JSON
  _intake.py split <parsed> <run>                              one <run>/<id>/notes.json per note
  _intake.py apply <notes> <ledger> <parsed> <results> <keep>  ledger the results, drop filed notes
  _intake.py tally <run>                                       the outcomes of every note in the run

A note is a top-level bullet ("- " or "* " at column 0) with every line under it that is blank
or indented, up to the next unindented line. Its section is the chain of headings above it. A
checked bullet ("- [x]") or one marked #promoted is not a note. The ledger (one JSON line per
handled note, keyed by the hash of its text) keeps a note from being filed twice, so a notes
file can also be read without being changed (keep = 1). apply removes a note by its exact text
from the file as it is now, so lines the owner added or changed during the run stay put."""
import hashlib, json, os, re, sys
from datetime import datetime, timezone

BULLET = re.compile(r"^[-*] ")
HEADING = re.compile(r"^(#+)\s+(.*?)\s*:?\s*$")
HANDLED = ("filed", "duplicate", "done")


def blocks(lines):
    sections, i = [], 0
    while i < len(lines):
        line = lines[i]
        heading = HEADING.match(line)
        if heading:
            depth = len(heading.group(1))
            sections = [s for s in sections if s[0] < depth] + [(depth, heading.group(2))]
            i += 1
            continue
        if not BULLET.match(line):
            i += 1
            continue
        j = i + 1
        while j < len(lines) and (not lines[j].strip() or lines[j][0] in " \t"):
            j += 1
        while j > i + 1 and not lines[j - 1].strip():
            j -= 1
        yield " > ".join(s[1] for s in sections), lines[i:j]
        i = j


def digest(text):
    return hashlib.sha1(" ".join(text.split()).encode()).hexdigest()[:16]


def ledgered(path):
    if not os.path.exists(path):
        return set()
    with open(path) as f:
        return {json.loads(l)["hash"] for l in f if l.strip()}


def parse(notes, ledger, batch):
    with open(notes) as f:
        lines = f.read().split("\n")
    seen, out, left = ledgered(ledger), [], 0
    for section, block in blocks(lines):
        head = block[0].lower()
        if head.startswith(("- [x]", "* [x]")) or "#promoted" in head:
            continue
        text = "\n".join(block)
        h = digest(text)
        if h in seen:
            continue
        if len(out) < batch:
            out.append({"id": "n%d" % (len(out) + 1), "hash": h, "section": section, "text": text})
        else:
            left += 1
    print(json.dumps({"notes": out, "left": left}, indent=1))


def remove(content, text):
    at = content.find(text)
    if at < 0:
        return content, False
    end = at + len(text)
    if content[end:end + 1] == "\n":
        end += 1
    content = content[:at] + content[end:]
    return re.sub(r"\n{3,}", "\n\n", content), True


def apply(notes, ledger, parsed, results, keep):
    with open(parsed) as f:
        by_id = {n["id"]: n for n in json.load(f)["notes"]}
    with open(results) as f:
        rows = json.load(f)
    with open(notes) as f:
        content = f.read()
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    counts = {}
    with open(ledger, "a") as log:
        for row in rows:
            note = by_id.get(row.get("note"))
            outcome = row.get("outcome", "")
            if not note:
                continue
            counts[outcome] = counts.get(outcome, 0) + 1
            if outcome not in HANDLED:
                continue
            log.write(json.dumps({"hash": note["hash"], "outcome": outcome, "issues": row.get("issues", []),
                                  "needs_owner": bool(row.get("needs_owner")), "at": stamp}) + "\n")
            if not keep:
                content, found = remove(content, note["text"])
                if not found:
                    print("%s: changed during the run, left in the file" % note["id"], file=sys.stderr)
    if not keep:
        with open(notes, "w") as f:
            f.write(content)
    owner = sum(1 for r in rows if r.get("needs_owner"))
    print(" ".join("%s %d" % (k, v) for k, v in sorted(counts.items())) + ("; %d need you" % owner if owner else ""))


def split(parsed, run):
    with open(parsed) as f:
        notes = json.load(f)["notes"]
    for note in notes:
        os.makedirs(os.path.join(run, note["id"]), exist_ok=True)
        with open(os.path.join(run, note["id"], "notes.json"), "w") as f:
            json.dump({"notes": [note], "left": 0}, f, indent=1)
        print(note["id"])


def tally(run):
    counts, owner = {}, 0
    for name in sorted(os.listdir(run)):
        if not os.path.isdir(os.path.join(run, name)):
            continue
        path = os.path.join(run, name, "results.json")
        rows = json.load(open(path)) if os.path.exists(path) else [{"outcome": "no-result"}]
        for row in rows:
            counts[row.get("outcome", "")] = counts.get(row.get("outcome", ""), 0) + 1
            owner += 1 if row.get("needs_owner") else 0
    print(" ".join("%s %d" % (k, v) for k, v in sorted(counts.items())) + ("; %d need you" % owner if owner else ""))


def main():
    command = sys.argv[1]
    if command == "parse":
        parse(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif command == "split":
        split(sys.argv[2], sys.argv[3])
    elif command == "tally":
        tally(sys.argv[2])
    elif command == "apply":
        apply(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6] == "1")
    else:
        sys.exit("flow: unknown command %s" % command)


main()

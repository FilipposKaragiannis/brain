"""Notes file plumbing for the intake job. See jobs/intake.sh.

  _intake.py parse <notes> <ledger> <batch>                    the next unfiled notes, as JSON
  _intake.py split <parsed> <run> [vocabulary]                 one <run>/<id>/notes.json per note
  _intake.py apply <notes> <ledger> <parsed> <results> <keep> <answers> <dropped>
                                                               ledger the results, drop handled notes
  _intake.py tally <run>                                       the outcomes of every note in the run

A note is a top-level bullet ("- " or "* " at column 0) with every line under it that is blank
or indented, up to the next unindented line. Its section is the chain of headings above it. A
checked bullet ("- [x]") or one marked #promoted is not a note. The first line may carry tags
(#bug), a handle (^id) and "#dup (see ^id)"; a sub-line "rel: ^a ^b" names related notes. A
parsed note carries its title without them, its tags, handle and related notes, and the items
already filed for those notes from the ledger. The ledger (one JSON line per handled note, keyed
by the hash of its text) keeps a note from being filed twice, so a notes file can also be read
without being changed (keep = 1). apply removes a note by its exact text from the file as it is
now, so lines the owner added or changed during the run stay put. An answered note's answer is
appended to the answers page and a dropped note's reason to the dropped page; a dropped note
without a reason, or an answered one without an answer, is kept."""
import hashlib, json, os, re, sys
from datetime import datetime, timezone

BULLET = re.compile(r"^[-*] ")
HEADING = re.compile(r"^(#+)\s+(.*?)\s*:?\s*$")
HANDLED = ("filed", "duplicate", "done", "answered", "dropped")
TAG = re.compile(r"(?<![\w&/])#([A-Za-z][\w-]*)")
DUP = re.compile(r"#dup\s*\(see\s+\^([\w-]+)\)", re.I)
HANDLE = re.compile(r"\^([A-Za-z0-9][\w-]*)")
REL = re.compile(r"^\s*[-*]\s*rel:\s*(.*)$", re.I)
ANSWERS_HEAD = ("# Answers\n\nQuestions from the notes, answered from the code and the docs by the intake job. "
                "Newest last.\n")
DROPPED_HEAD = "# Dropped notes\n\nNotes the intake job closed without an item, each with its reason. Newest last.\n\n"


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


def ledger_rows(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]


def describe(block):
    head = block[0]
    dup = DUP.search(head)
    rest = DUP.sub("", head)
    handles = HANDLE.findall(rest)
    rel = [h for line in block[1:] for m in [REL.match(line)] if m for h in HANDLE.findall(m.group(1))]
    title = re.sub(r"^[-*]\s+(\[.\]\s+)?", "", HANDLE.sub("", TAG.sub("", rest))).strip()
    tags = [t.lower() for t in TAG.findall(rest)]
    return {"title": title, "tags": tags, "ref": handles[-1] if handles else "",
            "dup": dup.group(1) if dup else "", "rel": rel,
            "question": "question" in tags or title.endswith("?")}


def related(note, rows):
    filed = {}
    for r in rows:
        if r.get("ref"):
            filed[r["ref"]] = r.get("issues", [])
    out = [{"ref": h, "issues": filed.get(h, []), "filed": h in filed} for h in [note["dup"]] + note["rel"] if h]
    if note["ref"]:
        out += [{"ref": r["ref"], "issues": r.get("issues", []), "filed": True}
                for r in rows if r.get("ref") and note["ref"] in r.get("rel", []) and r["ref"] not in [o["ref"] for o in out]]
    return out


def parse(notes, ledger, batch):
    with open(notes) as f:
        lines = f.read().split("\n")
    rows = ledger_rows(ledger)
    seen, out, left = {r["hash"] for r in rows}, [], 0
    for section, block in blocks(lines):
        head = block[0].lower()
        if head.startswith(("- [x]", "* [x]")) or "#promoted" in head:
            continue
        text = "\n".join(block)
        h = digest(text)
        if h in seen:
            continue
        if len(out) < batch:
            note = dict({"id": "n%d" % (len(out) + 1), "hash": h, "section": section, "text": text}, **describe(block))
            note["related"] = related(note, rows)
            out.append(note)
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
    before, after = content[:at], content[end:]
    if before.endswith("\n\n") and after.startswith("\n"):
        after = after[1:]
    return before + after, True


def append(path, head, entry):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fresh = not os.path.exists(path) or not os.path.getsize(path)
    with open(path, "a") as f:
        f.write((head if fresh else "") + entry)


def effective(row):
    outcome = row.get("outcome", "")
    if outcome == "answered" and not (row.get("answer") or "").strip():
        return "kept"
    if outcome == "dropped" and not (row.get("reason") or "").strip():
        return "kept"
    return outcome


def record(row, note, answers, dropped, day):
    outcome = row.get("outcome", "")
    title = row.get("title") or note.get("title") or note["text"].split("\n")[0]
    issues = ", ".join(row.get("issues", []))
    if outcome == "answered":
        if not (row.get("answer") or "").strip():
            return "kept", "%s: answered without an answer, kept" % note["id"]
        append(answers, ANSWERS_HEAD, "\n## %s\n\n%s\n\n_From the notes (%s), answered %s.%s_\n" % (
            title, row["answer"].strip(), note.get("section") or "no section", day,
            " Filed: %s." % issues if issues else ""))
    if outcome == "dropped":
        if not (row.get("reason") or "").strip():
            return "kept", "%s: dropped without a reason, kept" % note["id"]
        append(dropped, DROPPED_HEAD, "- **%s** (%s), %s: %s\n" % (
            title, note.get("section") or "no section", day, " ".join(row["reason"].split())))
    return outcome, ""


def apply(notes, ledger, parsed, results, keep, answers, dropped):
    with open(parsed) as f:
        by_id = {n["id"]: n for n in json.load(f)["notes"]}
    with open(results) as f:
        rows = json.load(f)
    with open(notes) as f:
        content = f.read()
    now = datetime.now(timezone.utc)
    stamp, day = now.strftime("%Y-%m-%dT%H:%M:%SZ"), now.strftime("%Y-%m-%d")
    counts = {}
    with open(ledger, "a") as log:
        for row in rows:
            note = by_id.get(row.get("note"))
            if not note:
                continue
            outcome, problem = record(row, note, answers, dropped, day)
            if problem:
                print(problem, file=sys.stderr)
            counts[outcome] = counts.get(outcome, 0) + 1
            if outcome not in HANDLED:
                continue
            log.write(json.dumps({"hash": note["hash"], "outcome": outcome, "issues": row.get("issues", []),
                                  "needs_owner": bool(row.get("needs_owner")), "ref": note.get("ref", ""),
                                  "rel": [h for h in [note.get("dup", "")] + note.get("rel", []) if h], "at": stamp}) + "\n")
            if not keep:
                content, found = remove(content, note["text"])
                if not found:
                    print("%s: changed during the run, left in the file" % note["id"], file=sys.stderr)
    if not keep:
        with open(notes, "w") as f:
            f.write(content)
    owner = sum(1 for r in rows if r.get("needs_owner"))
    print(" ".join("%s %d" % (k, v) for k, v in sorted(counts.items())) + ("; %d need you" % owner if owner else ""))


def split(parsed, run, vocabulary):
    with open(parsed) as f:
        notes = json.load(f)["notes"]
    words = {"types": [], "areas": []}
    if vocabulary and os.path.exists(vocabulary):
        try:
            words.update(json.load(open(vocabulary)))
        except ValueError:
            pass
    for note in notes:
        os.makedirs(os.path.join(run, note["id"]), exist_ok=True)
        with open(os.path.join(run, note["id"], "notes.json"), "w") as f:
            json.dump({"notes": [note], "left": 0, "types": words["types"], "areas": words["areas"]}, f, indent=1)
        print(note["id"])


def tally(run):
    counts, owner = {}, 0
    for name in sorted(os.listdir(run)):
        if not os.path.isdir(os.path.join(run, name)):
            continue
        path = os.path.join(run, name, "results.json")
        rows = json.load(open(path)) if os.path.exists(path) else [{"outcome": "no-result"}]
        for row in rows:
            counts[effective(row)] = counts.get(effective(row), 0) + 1
            owner += 1 if row.get("needs_owner") else 0
    print(" ".join("%s %d" % (k, v) for k, v in sorted(counts.items())) + ("; %d need you" % owner if owner else ""))


def main():
    command = sys.argv[1]
    if command == "parse":
        parse(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    elif command == "split":
        split(sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else "")
    elif command == "tally":
        tally(sys.argv[2])
    elif command == "apply":
        apply(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6] == "1", sys.argv[7], sys.argv[8])
    else:
        sys.exit("flow: unknown command %s" % command)


main()

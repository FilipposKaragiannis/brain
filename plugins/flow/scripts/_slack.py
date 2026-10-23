"""The Slack payload for one notification. See scripts/notify.sh.

  _slack.py <title> <link> <url> <gate> <item> <message>

Prints the webhook JSON: a plain-text fallback for the push preview, and Block Kit blocks that
lay the message out as a list. Numbered lines stay numbered, with their indented lines nested
under them; other lines are bullets; a long line of prose breaks into one bullet per sentence,
and a line of three or more ';'-separated parts into one bullet per part. Ids, commits, paths,
flags and code names read as code; a short label opening a line reads bold."""
import json, re, sys

LONG_LINE = 160
SENTENCE = re.compile(r"(?<=[.!?])\s+(?=[A-Za-z0-9`(])")
NUMBERED = re.compile(r"^(\d+)[.)]\s+(.*)")
LABEL = re.compile(r"^([A-Z][A-Za-z ]{0,24}):\s+")
URL = re.compile(r"https?://[^\s>)]+")
CODE = re.compile(
    r"`[^`]+`"
    r"|\b(?:gh|GH)#\d+\b|\blocal:[a-z]+/\d+\b"
    r"|(?<![\w/.-])--?[a-z][\w-]+"
    r"|\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}\b"
    r"|[\w.-]*/[\w./*-]+"
    r"|\b[\w-]+\.(?:cs|sh|py|md|json|ya?ml|toml|ts|js|html|log)\b"
    r"|\b(?=[A-Za-z][\w-]*\d)[A-Za-z]\w*(?:-\w+)+\b"
    r"|\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+\b"
    r"|\b[a-z]+[A-Z]\w*\b"
    r"|\b\w+_\w+\b")


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(t, **style):
    element = {"type": "text", "text": t}
    if style:
        element["style"] = style
    return element


def inline(line):
    """A line as rich-text elements: links, code spans and a bold opening label."""
    out = []
    m = LABEL.match(line)
    if m and len(m.group(1).split()) <= 3:
        out.append(text(m.group(1) + ": ", bold=True))
        line = line[m.end():]
    pos = 0
    for m in re.finditer("%s|%s" % (URL.pattern, CODE.pattern), line):
        if m.start() > pos:
            out.append(text(line[pos:m.start()]))
        token = m.group(0)
        if URL.fullmatch(token):
            out.append({"type": "link", "url": token})
        else:
            out.append(text(token.strip("`"), code=True))
        pos = m.end()
    if pos < len(line):
        out.append(text(line[pos:]))
    return out or [text(" ")]


def pieces(line):
    parts = [p.strip() for p in line.split(";") if p.strip()]
    if len(parts) < 3:
        parts = [line]
    return [s for p in parts for s in (SENTENCE.split(p) if len(p) > LONG_LINE or len(parts) > 1 else [p]) if s]


def items(message):
    """(style, indent, line) rows: ordered or bullet, top level or nested under a numbered line."""
    rows, under_number = [], False
    for raw in message.splitlines():
        if not raw.strip():
            continue
        line = raw.strip()
        m = NUMBERED.match(line)
        if m and raw == line:
            rows.append(("ordered", 0, m.group(2)))
            under_number = True
        elif raw != line and under_number:
            rows.extend(("bullet", 1, p) for p in pieces(line.lstrip("-* ")))
        else:
            under_number = False
            rows.extend(("bullet", 0, p) for p in pieces(line.lstrip("-* ")))
    return rows


def lists(rows):
    out, numbered = [], 0
    for style, indent, line in rows:
        if out and out[-1]["style"] == style and out[-1]["indent"] == indent:
            out[-1]["elements"].append({"type": "rich_text_section", "elements": inline(line)})
        else:
            out.append({"type": "rich_text_list", "style": style, "indent": indent,
                        "elements": [{"type": "rich_text_section", "elements": inline(line)}]})
            if style == "ordered" and indent == 0 and numbered:
                out[-1]["offset"] = numbered
        if style == "ordered" and indent == 0:
            numbered += 1
    return out


def body(message):
    rows = items(message)
    if len(rows) == 1 and rows[0][1] == 0 and rows[0][0] == "bullet":
        return [{"type": "rich_text_section", "elements": inline(rows[0][2])}]
    return lists(rows)


def main():
    title, link, url, gate, item, message = sys.argv[1:7]
    if gate:
        fallback_head = "*flow: %s* on %s" % (esc(gate), "<%s|%s>" % (url, esc(link)) if url else "*%s*" % esc(link))
        if url and item.startswith("gh#"):
            answer = "Answer on the issue: comment `/answer <your answer>`, or `/answer` alone for the recommendations."
        else:
            answer = "Answer in a session: `flow:gate %s \"<your answer>\"`" % item
        head = [text("Gate ", bold=True), text(gate, code=True), text(" on ")]
        head.append({"type": "link", "url": url, "text": link, "style": {"bold": True}} if url else text(link, bold=True))
        notes = [esc(answer)]
    else:
        fallback_head, answer, notes = "*%s*" % esc(title), "", []
        head = [text(title, bold=True)]
    blocks = [{"type": "rich_text", "elements": [{"type": "rich_text_section", "elements": head}]},
              {"type": "rich_text", "elements": body(message)}]
    if notes:
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": n} for n in notes]})
    fallback = "%s\n%s%s" % (fallback_head, esc(message), "\n" + answer if answer else "")
    print(json.dumps({"text": fallback, "blocks": blocks}))


main()

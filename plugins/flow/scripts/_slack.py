"""The Slack payload for one notification. See scripts/notify.sh.

  _slack.py <title> <link> <url> <gate> <item> <message>

Prints the webhook JSON: a plain-text fallback for the push preview, and Block Kit blocks that
lay the message out as a list. Numbered lines stay numbered, with their indented lines nested
under them; other lines are bullets; a long line of prose breaks into one bullet per sentence,
and a line of three or more ';'-separated parts into one bullet per part. Ids, commits, paths,
flags and code names read as code; a short label opening a line reads bold."""
import json, re, sys

LONG_LINE = 160      # characters of prose before a line breaks into sentences
MIN_PARTS = 3        # ';'-separated parts before a line breaks into one bullet per part
LABEL_WORDS = 3      # words at most in a bold opening label
LABEL_CHARS = 24     # characters at most in that label, after its capital
SHORT_HASH, FULL_HASH = 7, 40
SENTENCE = re.compile(r"(?<=[.!?])\s+(?=[A-Za-z0-9`(])")
NUMBERED = re.compile(r"^(\d+)[.)]\s+(.*)")
LABEL = re.compile(r"^([A-Z][A-Za-z ]{0,%d}):\s+" % LABEL_CHARS)
URL = re.compile(r"https?://[^\s>)]+")
CODE = re.compile(
    r"`[^`]+`"
    r"|\b(?:gh|GH)#\d+\b|\blocal:[a-z]+/\d+\b"
    r"|(?<![\w/.-])--?[a-z][\w-]+"
    r"|\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{%d,%d}\b" % (SHORT_HASH, FULL_HASH) +
    r"|[\w.-]*/[\w./*-]+"
    r"|\b[\w-]+\.(?:cs|sh|py|md|json|ya?ml|toml|ts|js|html|log)\b"
    r"|\b(?=[A-Za-z][\w-]*\d)[A-Za-z]\w*(?:-\w+)+\b"
    r"|\b[A-Z][a-z0-9]+(?:[A-Z][a-z0-9]+)+\b"
    r"|\b[a-z]+[A-Z]\w*\b"
    r"|\b\w+_\w+\b")


def escape(plain):
    return plain.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(content, **style):
    element = {"type": "text", "text": content}
    if style:
        element["style"] = style
    return element


def inline(line):
    out = []
    label = LABEL.match(line)
    if label and len(label.group(1).split()) <= LABEL_WORDS:
        out.append(text(label.group(1) + ": ", bold=True))
        line = line[label.end():]
    pos = 0
    for token in re.finditer("%s|%s" % (URL.pattern, CODE.pattern), line):
        if token.start() > pos:
            out.append(text(line[pos:token.start()]))
        if URL.fullmatch(token.group(0)):
            out.append({"type": "link", "url": token.group(0)})
        else:
            out.append(text(token.group(0).strip("`"), code=True))
        pos = token.end()
    if pos < len(line):
        out.append(text(line[pos:]))
    return out or [text(" ")]


def pieces(line):
    parts = [part.strip() for part in line.split(";") if part.strip()]
    if len(parts) < MIN_PARTS:
        parts = [line]
    out = []
    for part in parts:
        split = len(part) > LONG_LINE or len(parts) > 1
        out.extend(sentence for sentence in (SENTENCE.split(part) if split else [part]) if sentence)
    return out


def items(message):
    rows, under_number = [], False
    for raw in message.splitlines():
        if not raw.strip():
            continue
        line = raw.strip()
        numbered = NUMBERED.match(line)
        if numbered and raw == line:
            rows.append(("ordered", 0, numbered.group(2)))
            under_number = True
        elif raw != line and under_number:
            rows.extend(("bullet", 1, piece) for piece in pieces(line.lstrip("-* ")))
        else:
            under_number = False
            rows.extend(("bullet", 0, piece) for piece in pieces(line.lstrip("-* ")))
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
    url = url if url.startswith("https://") else ""
    if gate:
        fallback_head = "*flow: %s* on %s" % (escape(gate), "<%s|%s>" % (escape(url), escape(link)) if url else "*%s*" % escape(link))
        if url and item.startswith("gh#"):
            answer = "Answer on the issue: comment `/answer <your answer>`, or `/answer` alone for the recommendations."
        else:
            answer = "Answer in a session: `flow:gate %s \"<your answer>\"`" % item
        head = [text("Gate ", bold=True), text(gate, code=True), text(" on ")]
        head.append({"type": "link", "url": url, "text": link, "style": {"bold": True}} if url else text(link, bold=True))
        notes = [escape(answer)]
    else:
        fallback_head, answer, notes = "*%s*" % escape(title), "", []
        head = [text(title, bold=True)]
    blocks = [{"type": "rich_text", "elements": [{"type": "rich_text_section", "elements": head}]},
              {"type": "rich_text", "elements": body(message)}]
    if notes:
        blocks.append({"type": "context", "elements": [{"type": "mrkdwn", "text": note} for note in notes]})
    fallback = "%s\n%s%s" % (fallback_head, escape(message), "\n" + answer if answer else "")
    print(json.dumps({"text": fallback, "blocks": blocks}))


main()

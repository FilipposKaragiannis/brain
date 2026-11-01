"""The quiz the explain step writes (`<reports>/quiz.md`), parsed and graded. See quiz.sh.

  _quiz.py parse <quiz.md>                 the quiz as JSON
  _quiz.py grade <quiz.md> <answers...>    the result as JSON: "1b 2a 3c", or "b a c" in question order

The file shape, as skills/explain/SKILL.md asks for it:

  <!-- flow:quiz -->
  ## Quiz for <item>
  1. <question, one or more lines>
     a) <choice>
     b) <choice>
     Because: <why the right choice is right>
  <!-- answers: 1b 2a -->

Choices may share a line (`a) ... b) ... c) ...`). The Because line may run on over the lines
that follow it, up to the next question or the answers comment. A question with no key in the
answers comment has `answer` null and is never right.
"""
import json
import re
import sys

QUESTION = re.compile(r"^\s*(\d+)[.)]\s+(.*)$")
CHOICE = re.compile(r"(?:(?<=\s)|^)([a-h])\)\s*")
BECAUSE = re.compile(r"^\s*\**(?:because|why)\**\s*:\**\s*(.*)$", re.IGNORECASE)
ANSWERS = re.compile(r"<!--\s*answers:\s*([^>]*?)\s*-->", re.IGNORECASE)
TITLE = re.compile(r"^\s*#+\s*(.+?)\s*$")
KEY = re.compile(r"(\d+)\s*([a-h])", re.IGNORECASE)


def parse(text):
    title = None
    questions = []
    key = {}
    for found in ANSWERS.finditer(text):
        for number, letter in KEY.findall(found.group(1)):
            key[int(number)] = letter.lower()
    body = ANSWERS.sub("", text)
    body = re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)
    current = None
    for raw in body.split("\n"):
        line = raw.rstrip()
        if current is None:
            heading = TITLE.match(line)
            if heading and title is None:
                title = heading.group(1)
        started = QUESTION.match(line)
        if started and (current is None or not current["choices"] or int(started.group(1)) == current["number"] + 1):
            current = {"number": int(started.group(1)), "lines": [started.group(2)], "choices": [], "because": []}
            questions.append(current)
            continue
        if current is None or line.strip() == "":
            continue
        because = BECAUSE.match(line)
        if because:
            current["because"].append(because.group(1).strip())
            continue
        if current["because"]:
            current["because"].append(line.strip())
            continue
        current["lines"].append(line.strip())
    out = []
    for q in questions:
        text_lines = []
        choices = []
        for line in q["lines"]:
            parts = CHOICE.split(line)
            # parts: [text before first choice, letter, choice text, letter, choice text, ...]
            if len(parts) == 1:
                if choices:
                    choices[-1]["text"] = (choices[-1]["text"] + " " + line.strip()).strip()
                else:
                    text_lines.append(line.strip())
                continue
            if parts[0].strip():
                if choices:
                    choices[-1]["text"] = (choices[-1]["text"] + " " + parts[0].strip()).strip()
                else:
                    text_lines.append(parts[0].strip())
            for k in range(1, len(parts), 2):
                choices.append({"key": parts[k].lower(), "text": parts[k + 1].strip()})
        out.append({
            "number": q["number"],
            "text": " ".join(part for part in text_lines if part),
            "choices": choices,
            "answer": key.get(q["number"]),
            "because": " ".join(q["because"]) or None,
        })
    return {"title": title, "questions": out}


def given_answers(questions, words):
    """`1b 2a` names the questions; `b a c` goes in question order. Letters only, any case."""
    given = {}
    tokens = [t for w in words for t in w.replace(",", " ").split()]
    if all(KEY.fullmatch(t) for t in tokens):
        for t in tokens:
            number, letter = KEY.fullmatch(t).groups()
            given[int(number)] = letter.lower()
        return given
    for q, t in zip(questions, tokens):
        if re.fullmatch(r"[a-hA-H]", t):
            given[q["number"]] = t.lower()
    return given


def grade(quiz, words):
    questions = quiz["questions"]
    given = given_answers(questions, words)
    results = []
    for q in questions:
        got = given.get(q["number"])
        results.append({"number": q["number"], "given": got, "answer": q["answer"], "right": got is not None and got == q["answer"]})
    right = sum(1 for r in results if r["right"])
    return {"given": {str(k): v for k, v in given.items()}, "right": right, "total": len(questions), "passed": len(questions) > 0 and right == len(questions), "results": results}


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("parse", "grade"):
        sys.exit("usage: _quiz.py parse <quiz.md> | grade <quiz.md> <answers...>")
    with open(sys.argv[2], encoding="utf-8") as f:
        quiz = parse(f.read())
    if sys.argv[1] == "parse":
        print(json.dumps(quiz))
    else:
        print(json.dumps(grade(quiz, sys.argv[3:])))


if __name__ == "__main__":
    main()

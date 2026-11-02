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


def read_answer_key(text):
    """The `<!-- answers: 1b 2a -->` comments as {question number: letter}."""
    key = {}
    for found in ANSWERS.finditer(text):
        for number, letter in KEY.findall(found.group(1)):
            key[int(number)] = letter.lower()
    return key


def strip_comments(text):
    body = ANSWERS.sub("", text)
    return re.sub(r"<!--.*?-->", "", body, flags=re.DOTALL)


def read_title(lines):
    """The first heading above the first question."""
    for line in lines:
        if QUESTION.match(line):
            return None
        heading = TITLE.match(line)
        if heading:
            return heading.group(1)
    return None


def group_questions(lines):
    """Each question's number, its question and choice lines, and its Because lines."""
    blocks = []
    for line in lines:
        started = QUESTION.match(line)
        if started:
            blocks.append({"number": int(started.group(1)), "lines": [started.group(2)], "because": []})
        elif blocks and line.strip():
            add_line(blocks[-1], line.strip())
    return blocks


def add_line(block, line):
    """A Because line, and every line after it, belongs to the Because; any other line to the question."""
    because = BECAUSE.match(line)
    if because:
        block["because"].append(because.group(1).strip())
    elif block["because"]:
        block["because"].append(line)
    else:
        block["lines"].append(line)


def read_text_and_choices(lines):
    """`a)` starts a choice anywhere on a line. Text before the first choice is the question;
    text after a choice, on its line or the next, runs on that choice."""
    text_lines = []
    choices = []
    for line in lines:
        lead, *rest = CHOICE.split(line)
        run_on(text_lines, choices, lead.strip())
        for letter, choice in zip(rest[0::2], rest[1::2]):
            choices.append({"key": letter.lower(), "text": choice.strip()})
    return " ".join(text_lines), choices


def run_on(text_lines, choices, text):
    if not text:
        return
    if choices:
        choices[-1]["text"] = (choices[-1]["text"] + " " + text).strip()
    else:
        text_lines.append(text)


def build_question(block, key):
    text, choices = read_text_and_choices(block["lines"])
    return {
        "number": block["number"],
        "text": text,
        "choices": choices,
        "answer": key.get(block["number"]),
        "because": " ".join(block["because"]) or None,
    }


def parse(text):
    lines = [raw.rstrip() for raw in strip_comments(text).split("\n")]
    key = read_answer_key(text)
    return {"title": read_title(lines), "questions": [build_question(block, key) for block in group_questions(lines)]}


def given_answers(questions, words):
    """`1b 2a` names the questions; `b a c` goes in question order. Letters only, any case."""
    given = {}
    tokens = [token for word in words for token in word.replace(",", " ").split()]
    if all(KEY.fullmatch(token) for token in tokens):
        for token in tokens:
            number, letter = KEY.fullmatch(token).groups()
            given[int(number)] = letter.lower()
        return given
    for question, token in zip(questions, tokens):
        if re.fullmatch(r"[a-hA-H]", token):
            given[question["number"]] = token.lower()
    return given


def grade(quiz, words):
    questions = quiz["questions"]
    given = given_answers(questions, words)
    results = []
    for question in questions:
        got = given.get(question["number"])
        results.append({"number": question["number"], "given": got, "answer": question["answer"], "right": got is not None and got == question["answer"]})
    right = sum(1 for result in results if result["right"])
    return {"given": {str(number): letter for number, letter in given.items()}, "right": right, "total": len(questions), "passed": len(questions) > 0 and right == len(questions), "results": results}


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

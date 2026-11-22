"""Render the standards plugin's rule files from docs/coding-standards.md.

Outputs (all under plugins/standards/rules/):
  common/<nn>-<slug>.md   one file per language-neutral section, full text
  <language>.md           one file per "## Appendix <letter>. <Language>" section
  appendices.json         [{file, language, extensions}], one entry per appendix, from its Files line
  block.md                the compact block init installs into AGENTS.md (under 6 KB)
  index.json              {id: {title, tag, section, file}}
"""
import dataclasses
import json
import os
import re
import textwrap

SECTIONS = [
    ("## 0.", "00-usage"), ("## 1.", "01-design"), ("## 1b.", "02-architecture"),
    ("## 1c.", "03-performance"), ("## 2.", "04-state"), ("## 3.", "05-methods"),
    ("## 4.", "06-naming"), ("## 5.", "07-tests"), ("## 6.", "08-comments"),
    ("## 7.", "09-formatting"), ("## 8.", "10-workflow"),
]
HEADING_MARKER = "## "
APPENDIX = re.compile(r"^## Appendix [A-Z]\. (.+)$")
FILES = re.compile(r"^Files: (.+)$")
EXTENSION = re.compile(r"`(\.[A-Za-z0-9]+)`")
SENTENCE_END = re.compile(r"\.(?:\s|$)")
RULE = re.compile(r"^- \*\*([A-Z]+-\d\d)\*?\*? ?(.*)$")
TAG = re.compile(r"\[(hard|signal|judgement)[^\]]*\]")
CONVENTION_TAG = "convention"
USAGE_TAG = "usage"
USAGE_SLUG = "00-usage"
BLOCK_LIMIT = 6 * 1024
BLOCK_WIDTH = 100
SOURCE = os.path.join("docs", "coding-standards.md")


@dataclasses.dataclass(frozen=True)
class Parsed:
    sections: tuple
    problem: str


@dataclasses.dataclass(frozen=True)
class Rendered:
    files: dict
    problem: str


def language_slug(language: str) -> str:
    """The file name stem of a language's appendix: C# is csharp, Shell is shell."""
    spelled = language.lower().replace("#", "sharp").replace("+", "plus")
    return re.sub(r"[^a-z0-9]", "", spelled)


def new_section(line: str) -> dict:
    """The section a heading line opens, or an empty dict when the line opens none."""
    appendix = APPENDIX.match(line)
    if appendix:
        language = appendix.group(1).strip()
        return {"file": language_slug(language) + ".md", "slug": "", "language": language, "extensions": [],
                "heading": line[len(HEADING_MARKER):].strip(), "lines": [], "rules": []}
    matched = [slug for prefix, slug in SECTIONS if line.startswith(prefix)]
    if matched:
        return {"file": os.path.join("common", matched[0] + ".md"), "slug": matched[0], "language": "",
                "extensions": [], "heading": line[len(HEADING_MARKER):].strip(), "lines": [], "rules": []}
    return {}


def rule_entry(line: str, section: dict) -> dict:
    """The index entry of a rule line, or an empty dict when the line holds no rule."""
    matched = RULE.match(line)
    if not matched:
        return {}
    rule_id, rest = matched.group(1), matched.group(2)
    title = rest.split("**", 1)[0].strip().rstrip(".") if "**" in rest else SENTENCE_END.split(rest, 1)[0].strip()
    tag_match = TAG.search(rest)
    tag = tag_match.group(1) if tag_match else USAGE_TAG
    if section["language"]:
        tag = CONVENTION_TAG
    return {"id": rule_id, "title": title, "tag": tag, "text": line}


def appendix_extensions(section: dict) -> list:
    """The extensions an appendix's first Files line names; a common section has none."""
    files_lines = [FILES.match(line).group(1) for line in section["lines"] if FILES.match(line)]
    return EXTENSION.findall(files_lines[0]) if section["language"] and files_lines else []


def completed_section(section: dict) -> dict:
    """A copy of the section with its extensions and its rules read from its lines."""
    entries = [rule_entry(line, section) for line in section["lines"]]
    return dict(section, extensions=appendix_extensions(section), rules=[entry for entry in entries if entry])


def appendices_problem(sections: list) -> str:
    """Why an appendix cannot be scoped, or empty when every appendix names its file types."""
    unscoped = [section["heading"] for section in sections if section["language"] and not section["extensions"]]
    return "%s: %s has no 'Files: `.ext`' line naming the file types it covers" % (SOURCE, unscoped[0]) if unscoped else ""


def parse(path: str) -> Parsed:
    sections = []
    with open(path, encoding="utf-8") as source:
        text = source.read()
    for line in text.split("\n"):
        opened = new_section(line)
        if opened:
            sections.append(opened)
        elif sections:
            sections[-1]["lines"].append(line)
    completed = [completed_section(section) for section in sections]
    return Parsed(sections=tuple(completed), problem=appendices_problem(completed))


def appendix_sentence(sections: list) -> str:
    named = ["`.standards/rules/%s` (%s)" % (section["file"], section["language"]) for section in sections if section["language"]]
    listed = ", ".join(named[:-1]) + " and " + named[-1] if len(named) > 1 else "".join(named)
    return "Language conventions, one file per configured language: %s." % listed


def block_text(sections: list, version: str) -> str:
    hard, signal = [], []
    for section in sections:
        if section["language"] or section["slug"] == USAGE_SLUG:
            continue
        for rule in section["rules"]:
            if rule["tag"] == "hard":
                hard.append(rule)
            elif rule["tag"] == "signal":
                signal.append(rule)
    introduction = " ".join([
        "Full text with reasons in `.standards/rules/`. Cite rules by id. Rules bind new and touched",
        "code only; existing code is not refactored to meet a rule (U-05). A [judgement] breach is",
        "declared in the commit message, the PR body and the review (U-02).",
        appendix_sentence(sections),
        "Project rules outside this block win where they are stricter.",
    ])
    lines = ["# Coding standards (standards plugin v%s)" % version]
    lines += textwrap.wrap(introduction, width=BLOCK_WIDTH, break_on_hyphens=False)
    lines += ["", "## Hard rules (a breach blocks)"]
    lines += ["- %s %s." % (r["id"], r["title"]) for r in hard]
    lines += ["", "## Signals (split, or explain why not)"]
    lines += ["- %s %s." % (r["id"], r["title"]) for r in signal]
    lines += [
        "",
        "## Code Review Rules",
        "Review the touched code only. Cite every finding by rule id, file and line. A broken hard",
        "rule is P0 and blocks. A crossed signal with no explanation is P1 and blocks. A judgement",
        "disagreement is P2, a comment. Skip what the build and the hooks already enforce. Check the",
        "spec separately from the standards and never merge the two lists. Tests follow T-01 to",
        "T-13: a name of the shape Scenario_Outcome, a because string per assertion, one behaviour",
        "per test, no assertion on a double's calls.",
    ]
    return "\n".join(lines) + "\n"


def rule_index(sections: tuple) -> dict:
    """{id: {title, tag, section, file}} for every rule of every section."""
    return {rule["id"]: {"title": rule["title"], "tag": rule["tag"], "section": section["heading"], "file": section["file"]}
            for section in sections for rule in section["rules"]}


def render(root: str, version: str) -> Rendered:
    """The rule files by path, or no files and the problem when the source cannot render."""
    parsed = parse(os.path.join(root, SOURCE))
    if parsed.problem:
        return Rendered(files={}, problem=parsed.problem)
    block = block_text(list(parsed.sections), version)
    block_size = len(block.encode("utf-8"))
    if block_size > BLOCK_LIMIT:
        return Rendered(files={}, problem="%s: the compact block is %d bytes, over its %d byte limit" % (SOURCE, block_size, BLOCK_LIMIT))
    base = os.path.join("plugins", "standards", "rules")
    out = {os.path.join(base, section["file"]): "# " + section["heading"] + "\n\n" + "\n".join(section["lines"]).strip("\n") + "\n"
           for section in parsed.sections}
    appendices = [{"file": section["file"], "language": section["language"], "extensions": section["extensions"]}
                  for section in parsed.sections if section["language"]]
    out[os.path.join(base, "block.md")] = block
    out[os.path.join(base, "appendices.json")] = json.dumps(appendices, indent=2, ensure_ascii=False) + "\n"
    out[os.path.join(base, "index.json")] = json.dumps(rule_index(parsed.sections), indent=2, ensure_ascii=False) + "\n"
    return Rendered(files=out, problem="")

"""Render the standards plugin's rule files from docs/coding-standards.md.

Outputs (all under plugins/standards/rules/):
  common/<nn>-<slug>.md   one file per language-neutral section, full text
  csharp.md               the C# appendix
  block.md                the compact block init installs into AGENTS.md (under 6 KB)
  index.json              {id: {title, tag, section, file}}
"""
import json
import os
import re

SECTIONS = [
    ("## 0.", "00-usage"), ("## 1.", "01-design"), ("## 1b.", "02-architecture"),
    ("## 1c.", "03-performance"), ("## 2.", "04-state"), ("## 3.", "05-methods"),
    ("## 4.", "06-naming"), ("## 5.", "07-tests"), ("## 6.", "08-comments"),
    ("## 7.", "09-formatting"), ("## 8.", "10-workflow"), ("## Appendix A.", "csharp"),
]
RULE = re.compile(r"^- \*\*([A-Z]+-\d\d)\*?\*? ?(.*)$")
TAG = re.compile(r"\[(hard|signal|judgement)[^\]]*\]")
BLOCK_LIMIT = 6 * 1024


def parse(path):
    sections = []
    current = None
    for line in open(path, encoding="utf-8").read().split("\n"):
        matched = [slug for prefix, slug in SECTIONS if line.startswith(prefix)]
        if matched:
            current = {"slug": matched[0], "heading": line[3:].strip(), "lines": [], "rules": []}
            sections.append(current)
            continue
        if current is None:
            continue
        current["lines"].append(line)
        m = RULE.match(line)
        if m:
            rid, rest = m.group(1), m.group(2)
            title = rest.split("**", 1)[0].strip().rstrip(".") if "**" in rest else rest.split(".")[0].strip()
            tag_match = TAG.search(rest)
            tag = tag_match.group(1) if tag_match else ("convention" if rid.startswith("CS") else "usage")
            current["rules"].append({"id": rid, "title": title, "tag": tag, "text": line})
    return sections


def block_text(sections, version):
    hard, signal = [], []
    for s in sections:
        if s["slug"] in ("csharp", "00-usage"):
            continue
        for r in s["rules"]:
            if r["tag"] == "hard":
                hard.append(r)
            elif r["tag"] == "signal":
                signal.append(r)
    lines = [
        "# Coding standards (standards plugin v%s)" % version,
        "Full text with reasons in `.standards/rules/`. Cite rules by id. Rules bind new and touched",
        "code only; existing code is not refactored to meet a rule (U-05). A [judgement] breach is",
        "declared in the commit message, the PR body and the review (U-02). Language conventions:",
        "`.standards/rules/csharp.md`. Project rules outside this block win where they are stricter.",
        "",
        "## Hard rules (a breach blocks)",
    ]
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


def render(root, version):
    out = {}
    index = {}
    sections = parse(os.path.join(root, "docs", "coding-standards.md"))
    base = os.path.join("plugins", "standards", "rules")
    for s in sections:
        rel = os.path.join(base, "csharp.md") if s["slug"] == "csharp" else os.path.join(base, "common", s["slug"] + ".md")
        body = "\n".join(s["lines"]).strip("\n")
        out[rel] = "# " + s["heading"] + "\n\n" + body + "\n"
        for r in s["rules"]:
            index[r["id"]] = {"title": r["title"], "tag": r["tag"], "section": s["heading"], "file": os.path.relpath(rel, base)}
    out[os.path.join(base, "block.md")] = block_text(sections, version)
    out[os.path.join(base, "index.json")] = json.dumps(index, indent=2, ensure_ascii=False) + "\n"
    return out

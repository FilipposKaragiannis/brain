#!/usr/bin/env python3
"""Render the standards rule copies and the block for a project that relaxes rules.

`standards init` calls it only when .standards/config.json lists rule ids under `rules.relaxed`
(waived: never raised). Without the list init copies the plugin's files as they are.

    relaxed_rules.py --config .standards/config.json --index <plugin>/rules/index.json section <file>
    relaxed_rules.py --config .standards/config.json --index <plugin>/rules/index.json block <file>

`section` prints a rule file without the lines of the waived rules. `block` prints the block
without the waived ids and with a section that lists them, right before the review rules.
"""
import argparse
import dataclasses
import json
import sys

REVIEW_HEADING = "## Code Review Rules"
WAIVED_HEADING = "## Waived by this project (never raised; `.standards/config.json` rules.relaxed)"
OVERRIDE_SENTENCE = "These two lists override every other line of this block and of `.standards/rules/`."
RULE_LINE_PREFIXES = ("- **", "- ")
RULE_ID_ENDINGS = (" ", "*")


@dataclasses.dataclass(frozen=True)
class ProjectRules:
    waived: tuple


def read_text(path):
    with open(path, encoding="utf-8") as source:
        return source.read()


def project_rules(config):
    rules = config.get("rules") or {}
    return ProjectRules(waived=tuple(rules.get("relaxed") or ()))


def names_rule(line, rule_id):
    for prefix in RULE_LINE_PREFIXES:
        head = prefix + rule_id
        if line.startswith(head) and line[len(head):len(head) + 1] in RULE_ID_ENDINGS:
            return True
    return False


def without_rules(lines, rule_ids):
    return [line for line in lines if not any(names_rule(line, rule_id) for rule_id in rule_ids)]


def listed_rules(rule_ids, index):
    return ["- %s %s." % (rule_id, index[rule_id]["title"]) for rule_id in rule_ids if rule_id in index]


def project_sections(rules, index):
    if not rules.waived:
        return []
    return [WAIVED_HEADING] + listed_rules(rules.waived, index) + ["", OVERRIDE_SENTENCE, ""]


def section_text(text, rules, index):
    return "\n".join(without_rules(text.split("\n"), rules.waived))


def block_text(text, rules, index):
    lines = without_rules(text.split("\n"), rules.waived)
    if REVIEW_HEADING not in lines:
        sys.exit("relaxed_rules: the block has no '%s' heading" % REVIEW_HEADING)
    review_at = lines.index(REVIEW_HEADING)
    return "\n".join(lines[:review_at] + project_sections(rules, index) + lines[review_at:])


RENDERERS = {"section": section_text, "block": block_text}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--index", required=True)
    parser.add_argument("command", choices=sorted(RENDERERS))
    parser.add_argument("file")
    arguments = parser.parse_args()
    rules = project_rules(json.loads(read_text(arguments.config)))
    index = json.loads(read_text(arguments.index))
    rendered = RENDERERS[arguments.command](read_text(arguments.file), rules, index)
    sys.stdout.buffer.write(rendered.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())

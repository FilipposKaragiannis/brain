#!/usr/bin/env python3
"""Render the standards rule copies and the block for a project that relaxes rules.

`standards init` calls it only when .standards/config.json lists rule ids under `rules.relaxed`
(waived: never raised) or `rules.judgement` (demoted to judgement). Without the lists init copies
the plugin's files as they are.

    relaxed_rules.py --config .standards/config.json --index <plugin>/rules/index.json section <file>
    relaxed_rules.py --config .standards/config.json --index <plugin>/rules/index.json block <file>
    relaxed_rules.py --config .standards/config.json --index <plugin>/rules/index.json gaps

`section` prints a rule file without the lines of the waived rules and with the demoted rules
tagged judgement. `block` prints the block without the waived and demoted ids and with a section
for each list, right before the review rules. `gaps` prints one line per id the lists cannot take;
the other two leave those ids out.
"""
import argparse
import dataclasses
import json
import re
import sys

CONFIG_NAME = ".standards/config.json"
REVIEW_HEADING = "## Code Review Rules"
WAIVED_HEADING = "## Waived by this project (never raised; `.standards/config.json` rules.relaxed)"
DEMOTED_HEADING = "## Judgement in this project (P2 at most, declared per U-02; rules.judgement)"
OVERRIDE_SENTENCE = "These two lists override every other line of this block and of `.standards/rules/`."
RULE_LINE_PREFIXES = ("- **", "- ")
RULE_ID_ENDINGS = (" ", "*")
DEMOTABLE_TAG = re.compile(r"\[(hard|signal)\]")
DEMOTED_TAG = r"[judgement, relaxed from \1 by this project]"
DEMOTABLE_TAGS = ("hard", "signal")
USAGE_TAG = "usage"
USAGE_PREFIX = "U-"


@dataclasses.dataclass(frozen=True)
class ProjectRules:
    waived: tuple
    demoted: tuple
    gaps: tuple


def read_text(path):
    with open(path, encoding="utf-8") as source:
        return source.read()


def listed_ids(rules, key):
    value = rules.get(key) or []
    if not isinstance(value, list):
        return (), ("%s: rules.%s is not a list of rule ids" % (CONFIG_NAME, key),)
    return tuple(dict.fromkeys(str(entry) for entry in value)), ()


def id_gap(rule_id, key, index):
    if rule_id not in index:
        return "%s: rules.%s names %s, which is not a rule" % (CONFIG_NAME, key, rule_id)
    tag = index[rule_id]["tag"]
    if tag == USAGE_TAG or rule_id.startswith(USAGE_PREFIX):
        return "%s: rules.%s names %s, a usage rule; the usage rules are never relaxed" % (CONFIG_NAME, key, rule_id)
    if key == "judgement" and tag not in DEMOTABLE_TAGS:
        return "%s: rules.judgement names %s, a %s rule; only hard and signal rules are demoted" % (CONFIG_NAME, rule_id, tag)
    return ""


def project_rules(config, index):
    rules = config.get("rules") or {}
    if not isinstance(rules, dict):
        return ProjectRules(waived=(), demoted=(), gaps=("%s: rules is not an object" % CONFIG_NAME,))
    relaxed, relaxed_gaps = listed_ids(rules, "relaxed")
    judgement, judgement_gaps = listed_ids(rules, "judgement")
    in_both = tuple(rule_id for rule_id in relaxed if rule_id in judgement)
    gaps = list(relaxed_gaps + judgement_gaps)
    gaps += ["%s: rules names %s in both lists" % (CONFIG_NAME, rule_id) for rule_id in in_both]
    accepted = {}
    for key, rule_ids in (("relaxed", relaxed), ("judgement", judgement)):
        found = [(rule_id, id_gap(rule_id, key, index)) for rule_id in rule_ids if rule_id not in in_both]
        gaps += [gap for _, gap in found if gap]
        accepted[key] = tuple(rule_id for rule_id, gap in found if not gap)
    return ProjectRules(waived=accepted["relaxed"], demoted=accepted["judgement"], gaps=tuple(gaps))


def names_rule(line, rule_id):
    for prefix in RULE_LINE_PREFIXES:
        head = prefix + rule_id
        if line.startswith(head) and line[len(head):len(head) + 1] in RULE_ID_ENDINGS:
            return True
    return False


def names_any(line, rule_ids):
    return any(names_rule(line, rule_id) for rule_id in rule_ids)


def without_rules(lines, rule_ids):
    return [line for line in lines if not names_any(line, rule_ids)]


def demoted_line(line, rule_ids):
    if not names_any(line, rule_ids):
        return line
    return DEMOTABLE_TAG.sub(DEMOTED_TAG, line, count=1)


def listed_rules(rule_ids, index):
    return ["- %s %s." % (rule_id, index[rule_id]["title"]) for rule_id in rule_ids]


def project_sections(rules, index):
    listings = ((WAIVED_HEADING, rules.waived), (DEMOTED_HEADING, rules.demoted))
    sections = []
    for heading, rule_ids in listings:
        if rule_ids:
            sections += [heading] + listed_rules(rule_ids, index) + [""]
    if sections:
        sections += [OVERRIDE_SENTENCE, ""]
    return sections


def section_text(text, rules, index):
    lines = without_rules(text.split("\n"), rules.waived)
    return "\n".join(demoted_line(line, rules.demoted) for line in lines)


def block_text(text, rules, index):
    lines = without_rules(text.split("\n"), rules.waived + rules.demoted)
    if REVIEW_HEADING not in lines:
        sys.exit("relaxed_rules: the block has no '%s' heading" % REVIEW_HEADING)
    review_at = lines.index(REVIEW_HEADING)
    return "\n".join(lines[:review_at] + project_sections(rules, index) + lines[review_at:])


def gaps_text(rules):
    return "".join(gap + "\n" for gap in rules.gaps)


RENDERERS = {"section": section_text, "block": block_text}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--index", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in sorted(RENDERERS):
        commands.add_parser(name).add_argument("file")
    commands.add_parser("gaps")
    arguments = parser.parse_args()
    index = json.loads(read_text(arguments.index))
    rules = project_rules(json.loads(read_text(arguments.config)), index)
    if arguments.command in RENDERERS:
        rendered = RENDERERS[arguments.command](read_text(arguments.file), rules, index)
    else:
        rendered = gaps_text(rules)
    sys.stdout.buffer.write(rendered.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Changelog fragments: plugins/<plugin>/changelog.d/<slug>.md, one per PR that changes a plugin.

A fragment is a bump line, a blank line, then the bullets exactly as they land under a version
heading in the plugin's CHANGELOG.md, wrapped at 100 columns:

    bump: minor

    - What changed and why it matters.
      A continuation line is indented two spaces.

tools/release.sh folds them into a release (see docs/adr/0002-changelog-fragments.md).

Usage: fragments.py [ROOT]
  lint every plugins/*/changelog.d under ROOT (default: this repo): only .md files, each one
  well-formed. Prints one line per finding, exits 1 on any.
Needs python3 >= 3.9 and nothing else.
"""
import glob
import os
import re
import sys

BUMPS = ("patch", "minor", "major")  # lowest to highest
WIDTH = 100
BUMP_LINE = re.compile(r"^bump: (major|minor|patch)$")
BULLET = re.compile(r"^- \S")
CONTINUATION = re.compile(r"^  +\S")


def problem(text):
    """Why the fragment text is malformed, or None when it is well-formed."""
    lines = text.rstrip("\n").split("\n")
    if not BUMP_LINE.match(lines[0]):
        return "the first line must be 'bump: major', 'bump: minor' or 'bump: patch'"
    if len(lines) < 3 or lines[1] != "":
        return "a blank line and then the bullets must follow the bump line"
    if not BULLET.match(lines[2]):
        return "line 3 must start a bullet with '- '"
    for number, line in enumerate(lines[2:], start=3):
        if not (BULLET.match(line) or CONTINUATION.match(line)):
            return "line %d is neither a bullet ('- ') nor a continuation (indented two spaces)" % number
        if len(line) > WIDTH:
            return "line %d is over %d columns" % (number, WIDTH)
    return None


def bump(text):
    """The bump of a well-formed fragment: patch, minor or major."""
    return BUMP_LINE.match(text.split("\n", 1)[0]).group(1)


def bullets(text):
    """The bullet lines of a well-formed fragment, without the trailing newline."""
    return "\n".join(text.rstrip("\n").split("\n")[2:])


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def lint(root):
    findings = []
    for folder in sorted(glob.glob(os.path.join(root, "plugins", "*", "changelog.d"))):
        for name in sorted(os.listdir(folder)):
            path = os.path.join(folder, name)
            rel = os.path.relpath(path, root)
            if not (name.endswith(".md") and os.path.isfile(path)):
                findings.append("a changelog.d holds only .md files: %s" % rel)
                continue
            reason = problem(read_text(path))
            if reason:
                findings.append("malformed changelog fragment %s: %s" % (rel, reason))
    return findings


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    findings = lint(root)
    for finding in findings:
        print("lint: " + finding)
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())

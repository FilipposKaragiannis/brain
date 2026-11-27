"""The pull request body file scripts/_pr_publish.py hands to gh: read, swapped and written back.

The Verification section runs from its heading to the next `## ` heading, the `Resolves #<n>` or
`Item: <id>` line or the end, and a line inside a fence never ends it, so an excerpt that holds
such a line stays inside (swapped_section). A body with no section gets it before that footer
line, else at the end. The file is written through a temporary file beside it and os.replace.
"""
import os
import re
import tempfile
from dataclasses import dataclass
from typing import FrozenSet, List

from _pr_report import LINE_BREAK, SECTION_HEADING
from _pr_report_input import TEXT_ENCODING

HEADING_PREFIX = "## "
FOOTER_LINE = re.compile(r"(Resolves #\d+|Item: \S+)\s*$")
FENCE_OPENING = re.compile(r" {0,3}(`{3,}|~{3,})")
FENCE_CLOSING = r" {0,3}%s{%d,}\s*$"
NO_BODY = "no pull request body at %s: %s"
UNWRITTEN_BODY = "cannot write the pull request body %s: %s"


@dataclass(frozen=True)
class BodyRead:
    body: str
    problem: str


@dataclass(frozen=True)
class SectionSpan:
    start: int
    end: int


def fence_closes(line: str, opening: str) -> bool:
    return re.match(FENCE_CLOSING % (re.escape(opening[0]), len(opening)), line) is not None


def unfenced_positions(lines: List[str]) -> FrozenSet[int]:
    positions = set()
    opening = ""
    for position, line in enumerate(lines):
        if opening:
            opening = "" if fence_closes(line, opening) else opening
            continue
        fence = FENCE_OPENING.match(line)
        if fence:
            opening = fence.group(1)
            continue
        positions.add(position)
    return frozenset(positions)


def ends_section(line: str) -> bool:
    return line.startswith(HEADING_PREFIX) or FOOTER_LINE.match(line) is not None


def section_span(lines: List[str]) -> SectionSpan:
    open_positions = sorted(unfenced_positions(lines))
    start = next((position for position in open_positions if lines[position].rstrip() == SECTION_HEADING), None)
    if start is None:
        footer = next((position for position in open_positions if FOOTER_LINE.match(lines[position])), len(lines))
        return SectionSpan(footer, footer)
    end = next((position for position in open_positions if position > start and ends_section(lines[position])), len(lines))
    return SectionSpan(start, end)


def without_trailing_blank_lines(lines: List[str]) -> List[str]:
    kept = len(lines)
    while kept and not lines[kept - 1].strip():
        kept -= 1
    return lines[:kept]


def blank_line_beside(lines: List[str]) -> List[str]:
    return [""] if lines else []


def swapped_section(body: str, section: List[str]) -> str:
    lines = body.split(LINE_BREAK)
    span = section_span(lines)
    before = without_trailing_blank_lines(lines[:span.start])
    after = without_trailing_blank_lines(lines[span.end:])
    swapped = [*before, *blank_line_beside(before), *without_trailing_blank_lines(section), *blank_line_beside(after), *after]
    return LINE_BREAK.join(swapped) + LINE_BREAK


def read_body(path: str) -> BodyRead:
    try:
        with open(path, encoding=TEXT_ENCODING) as body_stream:
            return BodyRead(body_stream.read(), "")
    except (OSError, ValueError) as error:
        return BodyRead("", NO_BODY % (path, error))


def replace_body(path: str, body: str) -> str:
    folder, name = os.path.split(path)
    try:
        descriptor, temporary = tempfile.mkstemp(prefix=".%s." % name, dir=folder)
    except OSError as error:
        return UNWRITTEN_BODY % (path, error)
    try:
        with os.fdopen(descriptor, "w", encoding=TEXT_ENCODING) as temporary_stream:
            temporary_stream.write(body)
        os.replace(temporary, path)
    except OSError as error:
        return UNWRITTEN_BODY % (path, error)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)
    return ""

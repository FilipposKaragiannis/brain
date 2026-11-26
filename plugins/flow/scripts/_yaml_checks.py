"""The entries of a map of checks in the flow config, for verify. See lib/flow.sh yaml_checks.

  _yaml_checks.py <config file> <dotted.path>

Prints each entry of the map at the path, a command (a string) or a map {command, paths}, as
`<name> U+001F <command> U+001F <paths, one per line>` ending in U+001E, in file order. A missing
file, or a path the file does not hold, prints nothing. The reader covers the config's YAML
subset: two-space indents, quoted or plain scalars, a trailing # note, paths as an inline or a
block list."""

import re
import sys
from dataclasses import dataclass, replace
from itertools import dropwhile
from typing import Iterator, List

FIELD_SEPARATOR = "\x1f"
ENTRY_SEPARATOR = "\x1e"
INDENT_WIDTH = 2
QUOTES = ("'", '"')
TRAILING_NOTE = re.compile(r"[ \t]+#.*$")
BLANK_OR_COMMENT = re.compile(r"^[ \t]*(#|$)")
USAGE = "usage: _yaml_checks.py <config file> <dotted.path>"


@dataclass(frozen=True)
class Line:
    indent: float
    body: str

    @property
    def key(self) -> str:
        return unquote(self.body.split(":", 1)[0])

    @property
    def value(self) -> str:
        return unquote(self.body.split(":", 1)[1]) if ":" in self.body else ""

    @property
    def is_list_item(self) -> bool:
        return self.body.startswith("- ")


@dataclass(frozen=True)
class Entry:
    name: str
    command: str
    paths: str

    def record(self) -> str:
        return FIELD_SEPARATOR.join((self.name, self.command, self.paths)) + ENTRY_SEPARATOR


def unquote(text: str) -> str:
    text = text.strip(" \t")
    if len(text) >= 2 and text[0] in QUOTES and text[-1] == text[0]:
        return text[1:-1]
    return text


def read_lines(text: str) -> Iterator[Line]:
    for raw in text.split("\n"):
        if BLANK_OR_COMMENT.match(raw):
            continue
        body = raw.lstrip(" ")
        yield Line((len(raw) - len(body)) / INDENT_WIDTH, TRAILING_NOTE.sub("", body, count=1))


def inline_paths(text: str) -> str:
    inner = text[1:] if text.startswith("[") else text
    inner = inner[:-1] if inner.endswith("]") else inner
    return "".join(part + "\n" for part in (unquote(piece) for piece in inner.split(",")) if part)


def paths_of(value: str) -> str:
    if value.startswith("["):
        return inline_paths(value)
    return value + "\n" if value else ""


def map_lines(lines: Iterator[Line], keys: List[str]) -> Iterator[Line]:
    """The lines under the map the keys name, then the first line that leaves it."""
    depth = 0
    for line in lines:
        if line.is_list_item:
            continue
        if line.indent < depth:
            return
        if line.indent == depth and line.key == keys[depth]:
            depth += 1
            if depth == len(keys):
                yield from under(lines, depth)
                return


def under(lines: Iterator[Line], depth: int) -> Iterator[Line]:
    for line in lines:
        if line.indent < depth:
            return
        yield line


@dataclass(frozen=True)
class Draft:
    name: str
    command: str
    paths: str
    field: str


def is_entry_head(line: Line, depth: int) -> bool:
    return line.indent == depth and not line.is_list_item and ":" in line.body


def entry_blocks(lines: Iterator[Line], depth: int) -> Iterator[List[Line]]:
    block: List[Line] = []
    for line in dropwhile(lambda candidate: not is_entry_head(candidate, depth), lines):
        if is_entry_head(line, depth) and block:
            yield block
            block = []
        block.append(line)
    if block:
        yield block


def with_list_item(draft: Draft, line: Line, depth: int) -> Draft:
    if draft.field == "paths" and line.indent > depth:
        return replace(draft, paths=draft.paths + unquote(line.body[2:]) + "\n")
    return draft


def with_field(draft: Draft, line: Line) -> Draft:
    field = line.key
    command = line.value if field == "command" else draft.command
    paths = paths_of(line.value) if field == "paths" else draft.paths
    return Draft(draft.name, command, paths, field)


def after(draft: Draft, line: Line, depth: int) -> Draft:
    if line.is_list_item:
        return with_list_item(draft, line, depth)
    if line.indent == depth + 1 and ":" in line.body:
        return with_field(draft, line)
    return draft


def entry_of(block: List[Line], depth: int) -> Entry:
    head = block[0]
    draft = Draft(head.key, head.value, "", "")
    for line in block[1:]:
        draft = after(draft, line, depth)
    return Entry(draft.name, draft.command, draft.paths)


def entries(lines: Iterator[Line], depth: int) -> Iterator[Entry]:
    return (entry_of(block, depth) for block in entry_blocks(lines, depth))


def checks_at(text: str, dotted_path: str) -> List[Entry]:
    keys = dotted_path.split(".")
    return list(entries(map_lines(read_lines(text), keys), len(keys)))


def read_config(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as config:
            return config.read()
    except FileNotFoundError:
        return ""


def main(argv: List[str]) -> int:
    if len(argv) != 2:
        print(USAGE, file=sys.stderr)
        return 2
    sys.stdout.write("".join(entry.record() for entry in checks_at(read_config(argv[0]), argv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""The flat YAML subset of .flow/config.yaml, read line by line. See _config_migration.py.

The subset is the one yaml_get in lib/flow.sh reads: two spaces per level, `key: value`, nested
maps, block lists (`- item`) and inline lists (`[a, b]`). A trailing comment starts at the first
blank followed by `#`, and outer quotes are not part of a value. A file outside the subset is
refused whole: tab or odd indentation, a line that is neither `key:` nor `- item`, a key twice in
one map. The edits are in _config_yaml_edits.py.
"""

from __future__ import annotations

import enum
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple, Union

INDENT_STEP = 2
_ROOT_INDENT = -INDENT_STEP
_ROOT_PATH = ""
_LINE_PATTERN = re.compile(r"[^\n]*\n|[^\n]+$")
_TRAILING_COMMENT = re.compile(r"[ \t]+#")
_LIST_MARK = "- "
NEWLINE = "\n"
_EMPTY_LIST_ITEM = "-"
_QUOTES = "\"'"
_SHORTEST_QUOTED = 2


class LineKind(enum.Enum):
    BLANK = "blank"
    COMMENT = "comment"
    KEY = "key"
    ITEM = "item"


class FinalEnding(enum.Enum):
    TERMINATED = "terminated"
    UNTERMINATED = "unterminated"


@dataclass(frozen=True)
class Entry:
    kind: LineKind
    indent: int
    key: str
    value: str
    comment: str
    value_start: int
    comment_start: int


@dataclass(frozen=True)
class Line:
    text: str
    ending: str


@dataclass(frozen=True)
class KeyLine:
    path: str
    index: int


@dataclass(frozen=True)
class Document:
    lines: Tuple[Line, ...]
    entries: Tuple[Entry, ...]
    newline: str
    final_ending: FinalEnding
    keys: Tuple[KeyLine, ...]


@dataclass(frozen=True)
class Refusal:
    line_number: int
    reason: str


@dataclass(frozen=True)
class _OpenKey:
    indent: int
    path: str


_ROOT_KEY = _OpenKey(_ROOT_INDENT, _ROOT_PATH)


def _unquoted(text: str) -> str:
    stripped = text.strip(" \t")
    quoted = (
        len(stripped) >= _SHORTEST_QUOTED and stripped[0] == stripped[-1] and stripped[0] in _QUOTES
    )
    return stripped[1:-1] if quoted else stripped


def value_items(value_text: str) -> Tuple[str, ...]:
    """The values yaml_get prints for a key whose line holds this value text."""
    stripped = _unquoted(value_text)
    if not stripped.startswith("["):
        return (stripped,) if stripped else ()
    inner = stripped[1:].removesuffix("]")
    return tuple(item for item in (_unquoted(part) for part in inner.split(",")) if item)


def _indent_problem(text: str, indent: int) -> Optional[str]:
    if "\t" in text[:indent]:
        return "the line is indented with a tab"
    if indent % INDENT_STEP:
        return "the line is indented by %d spaces, not a multiple of %d" % (indent, INDENT_STEP)
    return None


def _content_entry(text: str, indent: int) -> Union[Entry, str]:
    comment_match = _TRAILING_COMMENT.search(text, indent)
    comment_start = comment_match.start() if comment_match else len(text)
    comment = text[comment_start:].lstrip(" \t")
    body = text[indent:comment_start].rstrip(" \t")
    if body == _EMPTY_LIST_ITEM or body.startswith(_LIST_MARK):
        item = body[len(_LIST_MARK) :].strip(" \t")
        return Entry(
            LineKind.ITEM, indent, "", item, comment, indent + len(_LIST_MARK), comment_start
        )
    colon = body.find(":")
    key = _unquoted(body[:colon]) if colon > 0 else ""
    if not key:
        return "the line is neither key: value nor - item"
    value = body[colon + 1 :].strip(" \t")
    return Entry(LineKind.KEY, indent, key, value, comment, indent + colon + 1, comment_start)


def _entry(text: str) -> Union[Entry, str]:
    content = text.lstrip(" \t")
    indent = len(text) - len(content)
    if not content.strip(" \t"):
        return Entry(LineKind.BLANK, indent, "", "", "", len(text), len(text))
    if content.startswith("#"):
        return Entry(LineKind.COMMENT, indent, "", "", content, len(text), indent)
    problem = _indent_problem(text, indent)
    return _content_entry(text, indent) if problem is None else problem


def _ending(raw: str) -> str:
    if raw.endswith("\r\n"):
        return "\r\n"
    return "\n" if raw.endswith("\n") else ""


def _item_problem(entry: Entry, open_keys: List[_OpenKey]) -> Optional[str]:
    if not open_keys:
        return "the list item belongs to no key"
    if entry.indent > open_keys[-1].indent + INDENT_STEP:
        return "the list item is indented deeper than its key's next level"
    return None


def _key_problem(
    entry: Entry, parent: _OpenKey, path: str, first_line: Optional[int]
) -> Optional[str]:
    if entry.indent != parent.indent + INDENT_STEP:
        return "the key is indented deeper than its map's next level"
    if first_line is not None:
        return "%s is set twice, first on line %d" % (path, first_line)
    return None


def _still_open(entry: Entry, open_keys: List[_OpenKey]) -> List[_OpenKey]:
    deepest_open = entry.indent if entry.kind is LineKind.ITEM else entry.indent - 1
    return [open_key for open_key in open_keys if open_key.indent <= deepest_open]


def _parent(open_keys: List[_OpenKey]) -> _OpenKey:
    return open_keys[-1] if open_keys else _ROOT_KEY


def _key_lines(entries: Tuple[Entry, ...]) -> Union[Tuple[KeyLine, ...], Refusal]:
    open_keys: List[_OpenKey] = []
    first_line_of: Dict[str, int] = {}
    key_lines: List[KeyLine] = []
    for index, entry in enumerate(entries):
        if entry.kind in (LineKind.BLANK, LineKind.COMMENT):
            continue
        open_keys = _still_open(entry, open_keys)
        if entry.kind is LineKind.ITEM:
            problem = _item_problem(entry, open_keys)
            if problem is not None:
                return Refusal(index + 1, problem)
            continue
        parent = _parent(open_keys)
        path = parent.path + "." + entry.key if parent.path else entry.key
        problem = _key_problem(entry, parent, path, first_line_of.get(path))
        if problem is not None:
            return Refusal(index + 1, problem)
        first_line_of[path] = index + 1
        key_lines.append(KeyLine(path, index))
        open_keys.append(_OpenKey(entry.indent, path))
    return tuple(key_lines)


def parse(text: str, newline_when_none: str) -> Union[Document, Refusal]:
    """The document, its new lines ending as its first line does, or as newline_when_none."""
    raw_lines = _LINE_PATTERN.findall(text)
    endings = [_ending(raw) for raw in raw_lines]
    newline = next((ending for ending in endings if ending), newline_when_none)
    unterminated = bool(endings) and not endings[-1]
    final_ending = FinalEnding.UNTERMINATED if unterminated else FinalEnding.TERMINATED
    lines: List[Line] = []
    entries: List[Entry] = []
    for number, (raw, ending) in enumerate(zip(raw_lines, endings), start=1):
        line_text = raw[: len(raw) - len(ending)]
        entry = _entry(line_text)
        if isinstance(entry, str):
            return Refusal(number, entry)
        lines.append(Line(line_text, ending or newline))
        entries.append(entry)
    key_lines = _key_lines(tuple(entries))
    if isinstance(key_lines, Refusal):
        return key_lines
    return Document(tuple(lines), tuple(entries), newline, final_ending, key_lines)


def rendered(lines: List[Line], final_ending: FinalEnding) -> str:
    text = "".join(line.text + line.ending for line in lines)
    if final_ending is FinalEnding.UNTERMINATED and lines:
        return text[: len(text) - len(lines[-1].ending)]
    return text


def render(document: Document) -> str:
    return rendered(list(document.lines), document.final_ending)


def key_paths(document: Document) -> Tuple[str, ...]:
    return tuple(key_line.path for key_line in document.keys)


def key_index(document: Document, path: str) -> Optional[int]:
    return next((key_line.index for key_line in document.keys if key_line.path == path), None)


def has_key(document: Document, path: str) -> bool:
    return key_index(document, path) is not None


def _in_block(key_entry: Entry, entry: Entry) -> bool:
    own_list = not key_entry.value and entry.kind is LineKind.ITEM
    return entry.indent > key_entry.indent or (own_list and entry.indent == key_entry.indent)


def block_end(document: Document, index: int) -> int:
    """One past the key's block: the lines indented deeper, and a list at its own indent."""
    key_entry = document.entries[index]
    end = index + 1
    for position in range(index + 1, len(document.entries)):
        entry = document.entries[position]
        member = _in_block(key_entry, entry)
        if entry.kind in (LineKind.KEY, LineKind.ITEM) and not member:
            break
        if entry.kind is not LineKind.BLANK and member:
            end = position + 1
    return end


def values(document: Document, path: str) -> Tuple[str, ...]:
    index = key_index(document, path)
    if index is None:
        return ()
    key_entry = document.entries[index]
    if key_entry.value:
        return value_items(key_entry.value)
    return _list_items(document, index)


def _list_items(document: Document, index: int) -> Tuple[str, ...]:
    key_entry = document.entries[index]
    items: List[str] = []
    for entry in document.entries[index + 1 :]:
        if entry.kind in (LineKind.BLANK, LineKind.COMMENT):
            continue
        if entry.kind is not LineKind.ITEM or entry.indent <= key_entry.indent:
            break
        if entry.value:
            items.append(_unquoted(entry.value))
    return tuple(items)

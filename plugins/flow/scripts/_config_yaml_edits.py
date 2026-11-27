"""Edits to the flat YAML subset _config_yaml.py reads. Each returns the new text with every other
line as it stood, its line ending too, so the owner's comments and layout stay: a comment line is
never moved or deleted, a trailing comment on a removed line stays as a comment line, and one on a
moved line moves with it.
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass
from typing import List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _config_yaml  # noqa: E402


@dataclass(frozen=True)
class _Insertion:
    position: int
    made_maps: Tuple[_config_yaml.Line, ...]
    depth: int


def _block(document: _config_yaml.Document, index: int) -> range:
    return range(index + 1, _config_yaml.block_end(document, index))


def _indent(depth: int) -> str:
    return " " * (depth * _config_yaml.INDENT_STEP)


def _holds_comment(
    document: _config_yaml.Document, index: int, left_as_comments: List[int]
) -> bool:
    if document.entries[index].comment:
        return True
    return any(
        document.entries[position].kind is _config_yaml.LineKind.COMMENT
        or (position in left_as_comments and document.entries[position].comment)
        for position in _block(document, index)
    )


def _holds_keys(document: _config_yaml.Document, index: int, removed: List[int]) -> bool:
    return any(
        document.entries[position].kind in (_config_yaml.LineKind.KEY, _config_yaml.LineKind.ITEM)
        and position not in removed
        for position in _block(document, index)
    )


def _left_empty(
    document: _config_yaml.Document, path: str, removed: List[int], left_as_comments: List[int]
) -> Optional[int]:
    index = _config_yaml.key_index(document, path)
    if index is None or _holds_keys(document, index, removed):
        return None
    return None if _holds_comment(document, index, left_as_comments) else index


def _key_and_item_lines(document: _config_yaml.Document, index: int) -> List[int]:
    return [
        position
        for position in range(index, _config_yaml.block_end(document, index))
        if document.entries[position].kind
        in (_config_yaml.LineKind.KEY, _config_yaml.LineKind.ITEM)
    ]


def _emptied_parents(
    document: _config_yaml.Document, path: str, taken: List[int], left_as_comments: List[int]
) -> List[int]:
    """The parent maps of the path left with no key and no comment once the taken lines go,
    innermost first; the lines left as comment lines count as comments."""
    emptied: List[int] = []
    parent_path = path.rpartition(".")[0]
    while parent_path:
        parent_index = _left_empty(document, parent_path, taken + emptied, left_as_comments)
        if parent_index is None:
            break
        emptied.append(parent_index)
        parent_path = parent_path.rpartition(".")[0]
    return emptied


def _map_lines(document: _config_yaml.Document, path: str) -> List[int]:
    names = path.split(".")
    found = (
        _config_yaml.key_index(document, ".".join(names[:depth])) for depth in range(1, len(names))
    )
    return [index for index in found if index is not None]


def without_key(document: _config_yaml.Document, path: str) -> str:
    """The text with the key's block gone. Its comments stay, a trailing one as a comment line, and
    a parent map left with no key and no comment goes too."""
    index = _config_yaml.key_index(document, path)
    if index is None:
        return _config_yaml.render(document)
    taken = _key_and_item_lines(document, index)
    removed = taken + _emptied_parents(document, path, taken, taken)
    kept: List[_config_yaml.Line] = []
    for position, line in enumerate(document.lines):
        entry = document.entries[position]
        if position not in removed:
            kept.append(line)
        elif entry.comment:
            kept.append(_config_yaml.Line(" " * entry.indent + entry.comment, line.ending))
    return _config_yaml.rendered(kept, document.final_ending)


def _insertion(document: _config_yaml.Document, path: str) -> _Insertion:
    """Where a new key goes: the end of its map's block, after the maps it lacks are made there; a
    missing map at the end of its own parent's block, a top-level one at the end of the file."""
    names = path.split(".")
    depth = len(names) - 1
    while depth > 0 and not _config_yaml.has_key(document, ".".join(names[:depth])):
        depth -= 1
    parent_index = _config_yaml.key_index(document, ".".join(names[:depth])) if depth else None
    position = (
        len(document.lines)
        if parent_index is None
        else _config_yaml.block_end(document, parent_index)
    )
    made_maps = tuple(
        _config_yaml.Line(_indent(level) + names[level] + ":", document.newline)
        for level in range(depth, len(names) - 1)
    )
    return _Insertion(position, made_maps, len(names) - 1)


def _inserted(
    document: _config_yaml.Document,
    insertion: _Insertion,
    added: List[_config_yaml.Line],
    removed: List[int],
) -> str:
    new_lines = list(insertion.made_maps) + added
    lines: List[_config_yaml.Line] = []
    for position, line in enumerate(document.lines):
        if position == insertion.position:
            lines.extend(new_lines)
        if position not in removed:
            lines.append(line)
    if insertion.position == len(document.lines):
        lines.extend(new_lines)
    return _config_yaml.rendered(lines, document.final_ending)


def with_key(document: _config_yaml.Document, path: str, value_text: str, comment: str) -> str:
    """The text with `key: value  # comment` at the end of its map's block (see _insertion)."""
    if _config_yaml.has_key(document, path):
        return _config_yaml.render(document)
    insertion = _insertion(document, path)
    trailing = "  " + comment if comment else ""
    key_text = path.rpartition(".")[2] + ": " + value_text + trailing
    added = [_config_yaml.Line(_indent(insertion.depth) + key_text, document.newline)]
    return _inserted(document, insertion, added, [])


def _carried(
    document: _config_yaml.Document, position: int, shift: int, new_name: str
) -> _config_yaml.Line:
    line = document.lines[position]
    entry = document.entries[position]
    if new_name:
        renamed = " " * (entry.indent + shift) + new_name + line.text[entry.value_start - 1 :]
        return _config_yaml.Line(renamed, line.ending)
    shifted = " " * shift + line.text if shift >= 0 else line.text[-shift:]
    return _config_yaml.Line(shifted, line.ending)


def moved(document: _config_yaml.Document, from_path: str, to_path: str) -> str:
    """The text with the key's line, renamed, and its key and item lines, re-indented by the depth
    difference, at the end of the new map's block (see _insertion), their trailing comments with
    them. Its comment lines stay, and a parent map left with no key and no comment goes. A file
    that already has the new key is left as it is."""
    index = _config_yaml.key_index(document, from_path)
    if index is None or _config_yaml.has_key(document, to_path):
        return _config_yaml.render(document)
    taken = _key_and_item_lines(document, index)
    shift = (to_path.count(".") - from_path.count(".")) * _config_yaml.INDENT_STEP
    new_name = to_path.rpartition(".")[2]
    carried = [
        _carried(document, position, shift, new_name if position == index else "")
        for position in taken
    ]
    target_maps = _map_lines(document, to_path)
    emptied = _emptied_parents(document, from_path, taken, [])
    removed = taken + [index for index in emptied if index not in target_maps]
    return _inserted(document, _insertion(document, to_path), carried, removed)


def with_value(document: _config_yaml.Document, path: str, value_text: str) -> str:
    """The text with the key's value replaced, its trailing comment kept."""
    index = _config_yaml.key_index(document, path)
    if index is None:
        return _config_yaml.render(document)
    line = document.lines[index]
    entry = document.entries[index]
    text = line.text[: entry.value_start] + " " + value_text + line.text[entry.comment_start :]
    lines = list(document.lines)
    lines[index] = _config_yaml.Line(text, line.ending)
    return _config_yaml.rendered(lines, document.final_ending)

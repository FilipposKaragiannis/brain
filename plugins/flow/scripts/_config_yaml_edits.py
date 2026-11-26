"""Edits to the flat YAML subset _config_yaml.py reads. Each returns the new text with every other
line as it stood, its line ending too, so the owner's comments and layout stay: a comment line is
never moved or deleted, and a trailing comment on a removed line stays as a comment line.
"""

from __future__ import annotations

import os
import sys
from typing import List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _config_yaml  # noqa: E402


def _block(document: _config_yaml.Document, index: int) -> range:
    return range(index + 1, _config_yaml.block_end(document, index))


def _holds_comment(document: _config_yaml.Document, index: int, removed: List[int]) -> bool:
    if document.entries[index].comment:
        return True
    return any(
        document.entries[position].kind is _config_yaml.LineKind.COMMENT
        or (position in removed and document.entries[position].comment)
        for position in _block(document, index)
    )


def _holds_keys(document: _config_yaml.Document, index: int, removed: List[int]) -> bool:
    return any(
        document.entries[position].kind in (_config_yaml.LineKind.KEY, _config_yaml.LineKind.ITEM)
        and position not in removed
        for position in _block(document, index)
    )


def _left_empty(document: _config_yaml.Document, path: str, removed: List[int]) -> Optional[int]:
    index = _config_yaml.key_index(document, path)
    if index is None or _holds_keys(document, index, removed):
        return None
    return None if _holds_comment(document, index, removed) else index


def without_key(document: _config_yaml.Document, path: str) -> str:
    """The text with the key's block gone. Its comments stay, a trailing one as a comment line, and
    a parent map left with no key and no comment goes too."""
    index = _config_yaml.key_index(document, path)
    if index is None:
        return _config_yaml.render(document)
    removed = [
        position
        for position in range(index, _config_yaml.block_end(document, index))
        if document.entries[position].kind
        in (_config_yaml.LineKind.KEY, _config_yaml.LineKind.ITEM)
    ]
    parent_path = path.rpartition(".")[0]
    parent_index = _left_empty(document, parent_path, removed) if parent_path else None
    while parent_index is not None:
        removed.append(parent_index)
        parent_path = parent_path.rpartition(".")[0]
        parent_index = _left_empty(document, parent_path, removed) if parent_path else None
    kept: List[_config_yaml.Line] = []
    for position, line in enumerate(document.lines):
        entry = document.entries[position]
        if position not in removed:
            kept.append(line)
        elif entry.comment:
            kept.append(_config_yaml.Line(" " * entry.indent + entry.comment, line.ending))
    return _config_yaml.rendered(kept, document.final_ending)


def with_key(document: _config_yaml.Document, path: str, value_text: str, comment: str) -> str:
    """The text with `key: value  # comment` at the end of its map's block; a missing map is made
    at the end of its own parent's block, a top-level one at the end of the file."""
    if _config_yaml.has_key(document, path):
        return _config_yaml.render(document)
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
    added = [
        _config_yaml.Line(
            " " * (level * _config_yaml.INDENT_STEP) + names[level] + ":", document.newline
        )
        for level in range(depth, len(names) - 1)
    ]
    trailing = "  " + comment if comment else ""
    key_text = names[-1] + ": " + value_text + trailing
    added.append(
        _config_yaml.Line(
            " " * ((len(names) - 1) * _config_yaml.INDENT_STEP) + key_text, document.newline
        )
    )
    lines = list(document.lines[:position]) + added + list(document.lines[position:])
    return _config_yaml.rendered(lines, document.final_ending)


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

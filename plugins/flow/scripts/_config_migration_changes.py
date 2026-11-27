"""What each step of flow's config migration does to the document, and how its keys must read
after it. See _config_migration.py.

remove takes a key's block out when the key is there. add writes `key: value  # comment` when it is
not. move gives the old key's block the new key's name and place when the new key is absent, and
when the new key is there already, even empty, removes the old key and says the new one wins.
known changes nothing. Each change is one line for the report: old key, new key, value and reason.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from typing import Callable, Dict, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _config_yaml  # noqa: E402
import _config_yaml_edits  # noqa: E402
from _config_migration_steps import AddStep, KnownStep, MoveStep, RemoveStep, Step  # noqa: E402

NONE = "-"
_FIELD_SEPARATOR = "\t"
_LINE_BREAKS = re.compile(r"[\t\r\n]")


@dataclass(frozen=True)
class Change:
    old_key: str
    new_key: str
    value: str
    reason: str

    def line(self) -> str:
        return _FIELD_SEPARATOR.join((self.old_key, self.new_key, self.value, self.reason))


@dataclass(frozen=True)
class Edit:
    text: str
    changes: Tuple[Change, ...]


@dataclass(frozen=True)
class Reading:
    """A key as the readers find it: there or not, and the values they print."""

    path: str
    present: bool
    items: Tuple[str, ...]


def report_value(items: Tuple[str, ...]) -> str:
    if not items:
        return NONE
    shown = items[0] if len(items) == 1 else "[" + ", ".join(items) + "]"
    return _LINE_BREAKS.sub(" ", shown)


def _unchanged(document: _config_yaml.Document) -> Edit:
    return Edit(_config_yaml.render(document), ())


def _removed(document: _config_yaml.Document, step: RemoveStep) -> Edit:
    if not _config_yaml.has_key(document, step.key):
        return _unchanged(document)
    old_value = report_value(_config_yaml.values(document, step.key))
    text = _config_yaml_edits.without_key(document, step.key)
    return Edit(text, (Change(step.key, NONE, old_value, step.reason),))


def _added(document: _config_yaml.Document, step: AddStep) -> Edit:
    if _config_yaml.has_key(document, step.key):
        return _unchanged(document)
    text = _config_yaml_edits.with_key(document, step.key, step.value_text, step.comment)
    new_value = report_value(_config_yaml.value_items(step.value_text))
    return Edit(text, (Change(NONE, step.key, new_value, step.reason),))


def _known(document: _config_yaml.Document, step: KnownStep) -> Edit:
    return _unchanged(document)


def _moved(document: _config_yaml.Document, step: MoveStep) -> Edit:
    if not _config_yaml.has_key(document, step.from_key):
        return _unchanged(document)
    old_value = report_value(_config_yaml.values(document, step.from_key))
    if _config_yaml.has_key(document, step.to_key):
        text = _config_yaml_edits.without_key(document, step.from_key)
        reason = "%s is set already and wins; %s" % (step.to_key, step.reason)
        return Edit(text, (Change(step.from_key, NONE, old_value, reason),))
    text = _config_yaml_edits.moved(document, step.from_key, step.to_key)
    return Edit(text, (Change(step.from_key, step.to_key, old_value, step.reason),))


_EDITS: Dict[type, Callable[[_config_yaml.Document, Step], Edit]] = {
    RemoveStep: _removed,
    AddStep: _added,
    KnownStep: _known,
    MoveStep: _moved,
}


def edit(document: _config_yaml.Document, step: Step) -> Edit:
    """The text after the step, and its change lines; the text as it stood when it does nothing."""
    return _EDITS[type(step)](document, step)


def _as_found(document: _config_yaml.Document, path: str) -> Reading:
    return Reading(path, _config_yaml.has_key(document, path), _config_yaml.values(document, path))


def _readings(document: _config_yaml.Document, step: Step) -> Tuple[Reading, ...]:
    if isinstance(step, RemoveStep):
        return (Reading(step.key, False, ()),)
    if isinstance(step, AddStep) and not _config_yaml.has_key(document, step.key):
        return (Reading(step.key, True, _config_yaml.value_items(step.value_text)),)
    if not isinstance(step, MoveStep):
        return (_as_found(document, step.key),)
    kept = _as_found(document, step.to_key)
    carried = _as_found(document, step.from_key)
    target = kept if kept.present else Reading(step.to_key, carried.present, carried.items)
    return (Reading(step.from_key, False, ()), target)


def left_as_it_says(
    before: _config_yaml.Document, after: _config_yaml.Document, step: Step
) -> bool:
    """Whether every key of the step reads after it as the step says it would."""
    return all(
        _config_yaml.has_key(after, reading.path) == reading.present
        and _config_yaml.values(after, reading.path) == reading.items
        for reading in _readings(before, step)
    )

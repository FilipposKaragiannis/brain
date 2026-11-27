"""The step list of standards' config migration, skills/init/migrations.json, read into typed
steps, and what the steps do to the config. See config_migration.py.

The list is {"steps": [...]}, run in its order. Each step has a name, an op and a reason for the
owner. The one op, add_in_each, names a top-level list, a `when` key and a key inside each element
(dotted for a nested one) and the value it writes: every element whose `when` key holds a value and
that has no such key gets it, so a second run changes nothing. A step of another op, one missing a
field, or a key whose path runs through a value that is not a map is a problem naming the step.
Each change is one line for the report: old key, new key, value and reason. The config is never
changed in place: each step returns a new one.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple, Union

_ENCODING = "utf-8"
_ADD_IN_EACH = "add_in_each"
_STEP_TEXT_FIELDS = ("name", "list", "when", "key", "reason")
_STEP_VALUE_FIELD = "value"
NONE = "-"
_FIELD_SEPARATOR = "\t"
_LINE_BREAKS = re.compile(r"[\t\r\n]")
_PATH_SEPARATOR = "."
_EMPTY_VALUES: Tuple[Any, ...] = (None, "", [], {})


@dataclass(frozen=True)
class Problem:
    reason: str


@dataclass(frozen=True)
class AddInEachStep:
    name: str
    list_key: str
    when: str
    key: str
    value: Any
    reason: str


@dataclass(frozen=True)
class Change:
    old_key: str
    new_key: str
    value: str
    reason: str

    def line(self) -> str:
        fields = (self.old_key, self.new_key, self.value, self.reason)
        return _FIELD_SEPARATOR.join(_LINE_BREAKS.sub(" ", field) for field in fields)


@dataclass(frozen=True)
class Stepped:
    config: Dict[str, Any]
    changes: Tuple[Change, ...]


def _step(entry: Any) -> Union[AddInEachStep, Problem]:
    if not isinstance(entry, dict) or entry.get("op") != _ADD_IN_EACH:
        return Problem("a step is not an %s step: %s" % (_ADD_IN_EACH, json.dumps(entry)))
    missing = [field for field in _STEP_TEXT_FIELDS if not isinstance(entry.get(field), str)]
    missing += [] if _STEP_VALUE_FIELD in entry else [_STEP_VALUE_FIELD]
    if missing:
        return Problem("a step lacks %s: %s" % (", ".join(missing), json.dumps(entry)))
    return AddInEachStep(
        entry["name"], entry["list"], entry["when"], entry["key"], entry["value"], entry["reason"]
    )


def _steps(entries: List[Any]) -> Union[Tuple[AddInEachStep, ...], Problem]:
    steps: List[AddInEachStep] = []
    for entry in entries:
        step = _step(entry)
        if isinstance(step, Problem):
            return step
        steps.append(step)
    if len({step.name for step in steps}) != len(steps):
        return Problem("two steps share a name")
    return tuple(steps)


def read_steps(step_list: str) -> Union[Tuple[AddInEachStep, ...], Problem]:
    try:
        with open(step_list, encoding=_ENCODING) as source:
            document = json.load(source)
    except (OSError, ValueError) as error:
        return Problem("cannot read the step list %s: %s" % (step_list, error))
    entries = document.get("steps") if isinstance(document, dict) else None
    if not isinstance(entries, list):
        return Problem("the step list %s holds no steps list" % step_list)
    return _steps(entries)


def _parent(mapping: Any, path: str) -> Optional[Dict[str, Any]]:
    node = mapping
    for part in path.split(_PATH_SEPARATOR)[:-1]:
        node = node.get(part) if isinstance(node, dict) else None
    return node if isinstance(node, dict) else None


def _leaf(path: str) -> str:
    return path.split(_PATH_SEPARATOR)[-1]


def _value(mapping: Any, path: str) -> Any:
    parent = _parent(mapping, path)
    return parent.get(_leaf(path)) if parent is not None else None


def _has(mapping: Any, path: str) -> bool:
    parent = _parent(mapping, path)
    return parent is not None and _leaf(path) in parent


def _qualifies(element: Any, step: AddInEachStep) -> bool:
    return _value(element, step.when) not in _EMPTY_VALUES and not _has(element, step.key)


def _with_key(mapping: Dict[str, Any], parts: List[str], value: Any) -> Union[Dict, Problem]:
    head = parts[0]
    if len(parts) == 1:
        return {**mapping, head: value}
    child = mapping.get(head, {})
    if not isinstance(child, dict):
        return Problem("%s is not a map" % head)
    inner = _with_key(child, parts[1:], value)
    if isinstance(inner, Problem):
        return inner
    return {**mapping, head: inner}


def _each_added(elements: List[Any], step: AddInEachStep) -> Union[List[Any], Problem]:
    parts = step.key.split(_PATH_SEPARATOR)
    added_elements: List[Any] = []
    for element in elements:
        added = _with_key(element, parts, step.value) if _qualifies(element, step) else element
        if isinstance(added, Problem):
            return added
        added_elements.append(added)
    return added_elements


def _changes(elements: List[Any], step: AddInEachStep) -> Tuple[Change, ...]:
    value = json.dumps(step.value, ensure_ascii=False)
    return tuple(
        Change(
            NONE, _PATH_SEPARATOR.join((step.list_key, str(index), step.key)), value, step.reason
        )
        for index, element in enumerate(elements)
        if _qualifies(element, step)
    )


def _stepped_once(config: Dict[str, Any], step: AddInEachStep) -> Union[Stepped, Problem]:
    elements = config.get(step.list_key)
    changes = _changes(elements, step) if isinstance(elements, list) else ()
    if not changes:
        return Stepped(config, ())
    added = _each_added(elements, step)
    if isinstance(added, Problem):
        return Problem("the step %s cannot set %s: %s" % (step.name, step.key, added.reason))
    return Stepped({**config, step.list_key: added}, changes)


def stepped(config: Dict[str, Any], steps: Tuple[AddInEachStep, ...]) -> Union[Stepped, Problem]:
    applied = Stepped(config, ())
    for step in steps:
        once = _stepped_once(applied.config, step)
        if isinstance(once, Problem):
            return once
        applied = Stepped(once.config, applied.changes + once.changes)
    return applied

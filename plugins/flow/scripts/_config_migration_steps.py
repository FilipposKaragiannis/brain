"""The step list of flow's config migration, skills/init/migrations.json, read into typed steps.
See _config_migration.py.

The list is {"steps": [...]}, run in its order. Each step has a name, an op, the key it is about
and a reason for the owner; an add step also has the value and the comment it writes. A step of
an op this helper does not take, or one missing a field, is a problem naming the step.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import List, Mapping, Optional, Tuple, Union

_ENCODING = "utf-8"
_COMMENT_MARK = "# "
_OPERATIONS = ("remove", "add", "known")


@dataclass(frozen=True)
class RemoveStep:
    name: str
    reason: str
    key: str


@dataclass(frozen=True)
class AddStep:
    name: str
    reason: str
    key: str
    value_text: str
    comment: str


@dataclass(frozen=True)
class KnownStep:
    name: str
    reason: str
    key: str


Step = Union[RemoveStep, AddStep, KnownStep]


@dataclass(frozen=True)
class Problem:
    reason: str


def _value_text(value: object) -> Optional[str]:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return value if value else '""'
    if isinstance(value, list) and all(isinstance(item, (str, int)) for item in value):
        return "[" + ", ".join(str(item) for item in value) + "]"
    return None


def _field(raw: Mapping[str, object], field: str) -> Optional[str]:
    value = raw.get(field)
    return value if isinstance(value, str) and value else None


def _step(raw: object) -> Union[Step, Problem]:
    if not isinstance(raw, dict):
        return Problem("a step is not an object")
    name = _field(raw, "name") or "?"
    operation = raw.get("op")
    if operation not in _OPERATIONS:
        return Problem(
            "the step %s has the op %s, which this helper does not take" % (name, operation)
        )
    reason = _field(raw, "reason")
    key = _field(raw, "key")
    if reason is None or key is None:
        return Problem("the step %s needs a key and a reason" % name)
    if operation == "remove":
        return RemoveStep(name, reason, key)
    if operation == "known":
        return KnownStep(name, reason, key)
    return _add_step(raw, name, reason, key)


def _add_step(raw: Mapping[str, object], name: str, reason: str, key: str) -> Union[Step, Problem]:
    value_text = _value_text(raw.get("value"))
    comment = raw.get("comment", "")
    if value_text is None or not isinstance(comment, str):
        return Problem("the add step %s needs a value and a text comment" % name)
    return AddStep(name, reason, key, value_text, _COMMENT_MARK + comment if comment else "")


def read_steps(step_list: str) -> Union[Tuple[Step, ...], Problem]:
    try:
        with open(step_list, encoding=_ENCODING) as step_file:
            listed = json.load(step_file)
    except (OSError, ValueError) as error:
        return Problem("cannot read the step list %s: %s" % (step_list, error))
    raw_steps = listed.get("steps") if isinstance(listed, dict) else None
    if not isinstance(raw_steps, list):
        return Problem("the step list %s has no steps list" % step_list)
    typed_steps: List[Step] = []
    for raw in raw_steps:
        step = _step(raw)
        if isinstance(step, Problem):
            return Problem("%s: %s" % (step_list, step.reason))
        typed_steps.append(step)
    return tuple(typed_steps)

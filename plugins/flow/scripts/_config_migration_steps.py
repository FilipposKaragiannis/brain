"""The step list of flow's config migration, skills/init/migrations.json, read into typed steps.
See _config_migration.py.

The list is {"steps": [...]}, run in its order. Each step has a name, an op and a reason for the
owner. A remove, add or known step names its key; an add step also has the value and the comment
it writes. A move step names the key it moves from and the key it moves to, neither inside the
other. A step of an op this helper does not take, or one missing a field, is a problem naming the
step. The fallback field is for the lint and is not read here.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Callable, Dict, List, Mapping, Optional, Tuple, Union

_ENCODING = "utf-8"
_COMMENT_MARK = "# "
_UNNAMED = "?"


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


@dataclass(frozen=True)
class MoveStep:
    name: str
    reason: str
    from_key: str
    to_key: str


Step = Union[RemoveStep, AddStep, KnownStep, MoveStep]


@dataclass(frozen=True)
class Problem:
    reason: str


def step_keys(step: Step) -> Tuple[str, ...]:
    """The keys the step may change."""
    if isinstance(step, MoveStep):
        return (step.from_key, step.to_key)
    return (step.key,)


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


def _needs_a_key(name: str) -> Problem:
    return Problem("the step %s needs a key and a reason" % name)


def _remove_step(raw: Mapping[str, object], name: str) -> Union[Step, Problem]:
    reason = _field(raw, "reason")
    key = _field(raw, "key")
    if reason is None or key is None:
        return _needs_a_key(name)
    return RemoveStep(name, reason, key)


def _known_step(raw: Mapping[str, object], name: str) -> Union[Step, Problem]:
    reason = _field(raw, "reason")
    key = _field(raw, "key")
    if reason is None or key is None:
        return _needs_a_key(name)
    return KnownStep(name, reason, key)


def _add_step(raw: Mapping[str, object], name: str) -> Union[Step, Problem]:
    reason = _field(raw, "reason")
    key = _field(raw, "key")
    if reason is None or key is None:
        return _needs_a_key(name)
    value_text = _value_text(raw.get("value"))
    comment = raw.get("comment", "")
    if value_text is None or not isinstance(comment, str):
        return Problem("the add step %s needs a value and a text comment" % name)
    return AddStep(name, reason, key, value_text, _COMMENT_MARK + comment if comment else "")


def _nested(outer: str, inner: str) -> bool:
    return inner == outer or inner.startswith(outer + ".")


def _move_step(raw: Mapping[str, object], name: str) -> Union[Step, Problem]:
    reason = _field(raw, "reason")
    from_key = _field(raw, "from")
    to_key = _field(raw, "to")
    if reason is None or from_key is None or to_key is None:
        return Problem("the move step %s needs a from, a to and a reason" % name)
    if _nested(from_key, to_key) or _nested(to_key, from_key):
        return Problem("the move step %s moves %s inside itself" % (name, from_key))
    return MoveStep(name, reason, from_key, to_key)


_READERS: Dict[str, Callable[[Mapping[str, object], str], Union[Step, Problem]]] = {
    "remove": _remove_step,
    "add": _add_step,
    "known": _known_step,
    "move": _move_step,
}


def _step(raw: object) -> Union[Step, Problem]:
    if not isinstance(raw, dict):
        return Problem("a step is not an object")
    name = _field(raw, "name") or _UNNAMED
    operation = raw.get("op")
    reader = _READERS.get(operation) if isinstance(operation, str) else None
    if reader is None:
        return Problem(
            "the step %s has the op %s, which this helper does not take" % (name, operation)
        )
    return reader(raw, name)


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

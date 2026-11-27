"""The step list of flow's config migration, skills/init/migrations.json, read into typed steps.
See _config_migration.py.

The list is {"steps": [...]}, run in its order. Each step has a name, an op and a reason for the
owner. A remove, add or known step names its key; an add step also has the value and the comment
it writes. A move step names the key it moves from and the key it moves to, neither inside the
other. A spread step names the map it spreads from, the names of the leaves it copies, the maps
directly inside that map it copies them into, none of them a leaf's name, and optionally, per new
leaf, a table of the values it writes in place of the old ones. A step of an op this helper does
not take, or one missing a field, is a problem naming the step. The fallback field is for the lint
and is not read here.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from types import MappingProxyType
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


@dataclass(frozen=True)
class SpreadStep:
    name: str
    reason: str
    from_key: str
    leaf_names: Tuple[str, ...]
    to_keys: Tuple[str, ...]
    value_tables: Mapping[str, Mapping[str, str]]


Step = Union[RemoveStep, AddStep, KnownStep, MoveStep, SpreadStep]


@dataclass(frozen=True)
class Problem:
    reason: str


def step_keys(step: Step) -> Tuple[str, ...]:
    """The keys the step may change."""
    if isinstance(step, MoveStep):
        return (step.from_key, step.to_key)
    if isinstance(step, SpreadStep):
        return leaf_paths((step.from_key,) + step.to_keys, step.leaf_names)
    return (step.key,)


def leaf_paths(map_keys: Tuple[str, ...], leaf_names: Tuple[str, ...]) -> Tuple[str, ...]:
    """Each leaf's path in each map, map by map."""
    return tuple(map_key + "." + leaf_name for map_key in map_keys for leaf_name in leaf_names)


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


def _names(raw: object) -> Optional[Tuple[str, ...]]:
    """The list's entries when it is a list of distinct key names with no dot, else None."""
    if not isinstance(raw, list) or not raw:
        return None
    if not all(isinstance(entry, str) and entry and "." not in entry for entry in raw):
        return None
    return tuple(raw) if len(set(raw)) == len(raw) else None


def _table(raw: object) -> Optional[Mapping[str, str]]:
    if not isinstance(raw, dict):
        return None
    if not all(isinstance(old, str) and isinstance(new, str) and new for old, new in raw.items()):
        return None
    return MappingProxyType(dict(raw))


def _value_tables(
    raw: object, new_leaves: Tuple[str, ...]
) -> Optional[Mapping[str, Mapping[str, str]]]:
    """The tables by new leaf, when each names one of the new leaves; none at all is no table."""
    if raw is None:
        return MappingProxyType({})
    if not isinstance(raw, dict) or not set(raw) <= set(new_leaves):
        return None
    tables = {new_leaf: _table(table) for new_leaf, table in raw.items()}
    if any(table is None for table in tables.values()):
        return None
    return MappingProxyType(tables)


def _to_keys(raw: object, from_key: str) -> Optional[Tuple[str, ...]]:
    """The maps a spread writes, when each is a distinct map directly in from_key, else None."""
    if not isinstance(raw, list):
        return None
    prefix = from_key + "."
    inside = [
        entry[len(prefix) :] for entry in raw if isinstance(entry, str) and entry.startswith(prefix)
    ]
    names = _names(inside)
    return None if names is None or len(names) != len(raw) else tuple(raw)


def _spread_step(raw: Mapping[str, object], name: str) -> Union[Step, Problem]:
    reason = _field(raw, "reason")
    from_key = _field(raw, "from")
    leaf_names = _names(raw.get("keys"))
    to_keys = _to_keys(raw.get("to"), from_key) if from_key is not None else None
    if reason is None or from_key is None or leaf_names is None or to_keys is None:
        return Problem(
            "the spread step %s needs a from, keys, a to of maps in it and a reason" % name
        )
    if set(leaf_paths((from_key,), leaf_names)) & set(to_keys):
        return Problem("the spread step %s spreads into one of its own leaves" % name)
    value_tables = _value_tables(raw.get("values"), leaf_paths(to_keys, leaf_names))
    if value_tables is None:
        return Problem("the spread step %s has values for a key it does not write" % name)
    return SpreadStep(name, reason, from_key, leaf_names, to_keys, value_tables)


_READERS: Dict[str, Callable[[Mapping[str, object], str], Union[Step, Problem]]] = {
    "remove": _remove_step,
    "add": _add_step,
    "known": _known_step,
    "move": _move_step,
    "spread": _spread_step,
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

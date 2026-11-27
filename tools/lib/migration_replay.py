"""The replay half of migration_steps.py: flow's typed migration steps run over the frozen key
baseline, and what the result says about the schema mirror and the fallbacks.

A remove or move step retires the key it names and every baseline key under it; a spread step
retires each old leaf. A move step introduces its new key and the keys it carries under it, a
spread step each new leaf, an add or known step only the key it names. A key a step retires is
retired even when the baseline lacks it, so no later step may bring it back. A fallback file
passes while its text names at least one key its step retires.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Dict, FrozenSet, List, Mapping, Optional, Sequence, Tuple

from _config_migration_steps import (
    AddStep,
    KnownStep,
    MoveStep,
    RemoveStep,
    SpreadStep,
    Step,
    leaf_paths,
)

_ENCODING = "utf-8"
_KEY_SEPARATOR = "."


@dataclass(frozen=True)
class Fallback:
    after: Tuple[int, ...]
    files: Tuple[str, ...]


@dataclass(frozen=True)
class KeyList:
    keys: FrozenSet[str]
    deprecated: FrozenSet[str]


@dataclass(frozen=True)
class Replay:
    live: FrozenSet[str]
    retired_by: Mapping[str, str]
    findings: Tuple[str, ...]


def _under(key: str, parent: str) -> bool:
    return key == parent or key.startswith(parent + _KEY_SEPARATOR)


def _with_children(named: Tuple[str, ...], live: FrozenSet[str]) -> FrozenSet[str]:
    return frozenset(named) | {key for key in live for parent in named if _under(key, parent)}


def old_keys(step: object) -> Tuple[str, ...]:
    """The keys a step names as the ones it takes out; none for a step of another plugin."""
    if isinstance(step, RemoveStep):
        return (step.key,)
    if isinstance(step, MoveStep):
        return (step.from_key,)
    if isinstance(step, SpreadStep):
        return leaf_paths((step.from_key,), step.leaf_names)
    return ()


def _retired(step: Step, live: FrozenSet[str]) -> FrozenSet[str]:
    return _with_children(old_keys(step), live)


def _introduced(step: Step, live: FrozenSet[str]) -> FrozenSet[str]:
    if isinstance(step, MoveStep):
        moved = _with_children((step.from_key,), live)
        return frozenset(step.to_key + key[len(step.from_key) :] for key in moved)
    if isinstance(step, SpreadStep):
        return frozenset(leaf_paths(step.to_keys, step.leaf_names))
    if isinstance(step, (AddStep, KnownStep)):
        return frozenset((step.key,))
    return frozenset()


def replay(baseline: FrozenSet[str], steps: Sequence[Step]) -> Replay:
    live = baseline
    retired_by: Dict[str, str] = {}
    findings: List[str] = []
    for step in steps:
        introduced = _introduced(step, live)
        findings += [
            "the step %s brings back %s, which the step %s retired"
            % (step.name, key, retired_by[key])
            for key in sorted(introduced & set(retired_by))
        ]
        retired = _retired(step, live)
        retired_by.update({key: step.name for key in retired if key not in retired_by})
        live = (live - retired) | introduced
    return Replay(live, retired_by, tuple(findings))


def mirror_findings(
    mirror: KeyList, replayed: Replay, fallbacks: Mapping[str, Fallback], mirror_name: str
) -> Tuple[str, ...]:
    added = sorted(mirror.keys - replayed.live - set(replayed.retired_by))
    removed = sorted(replayed.live - mirror.keys)
    lingering = sorted(mirror.keys & set(replayed.retired_by))
    return (
        tuple("flow schema key added without a migration step: %s" % key for key in added)
        + tuple("flow schema key removed without a migration step: %s" % key for key in removed)
        + tuple(
            "%s is retired by the step %s but not marked deprecated in %s"
            % (key, replayed.retired_by[key], mirror_name)
            for key in lingering
            if key not in mirror.deprecated
        )
        + tuple(
            "%s is retired by the step %s, which carries no fallback: take it out of the schema"
            % (key, replayed.retired_by[key])
            for key in lingering
            if replayed.retired_by[key] not in fallbacks
        )
    )


def _text(path: str) -> Optional[str]:
    try:
        with open(path, encoding=_ENCODING) as source:
            return source.read()
    except OSError:
        return None


def _file_finding(
    step_name: str, keys: Tuple[str, ...], plugin_root: str, file: str
) -> Optional[str]:
    text = _text(os.path.join(plugin_root, file))
    if text is None:
        return "the fallback file %s of the step %s is missing" % (file, step_name)
    if any(key in text for key in keys):
        return None
    return "the fallback file %s of the step %s no longer names %s: take the entry out" % (
        file,
        step_name,
        " or ".join(keys),
    )


def tie_findings(
    retiring: Mapping[str, Tuple[str, ...]], fallbacks: Mapping[str, Fallback], plugin_root: str
) -> Tuple[str, ...]:
    """Each fallback against the keys its step retires (retiring: step name to its old keys)."""
    findings: List[Optional[str]] = []
    for step_name, fallback in fallbacks.items():
        keys = retiring.get(step_name, ())
        if not keys:
            findings.append("the step %s retires no key, so it carries no fallback" % step_name)
            continue
        findings += [_file_finding(step_name, keys, plugin_root, file) for file in fallback.files]
    return tuple(finding for finding in findings if finding is not None)

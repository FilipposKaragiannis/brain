"""Lint the config migration steps of flow and standards (docs/adr/0004-config-migrations.md).

Usage: python3 -I -B tools/lib/migration_steps.py ROOT

Both step lists under ROOT, plugins/<plugin>/skills/init/migrations.json, must read with the
plugin's own reader, and each step needs a unique name of lowercase words joined by hyphens (so
no ticket id fits), a reason, and a fallback, when it has one, of an `after` version and the
plugin files that still read the old key. Flow's steps are then replayed over
tools/config-keys/flow-baseline.txt, which is never edited, and the keys that result must be the
ones tools/config-keys/flow-schema.txt mirrors from the console's schema (see
migration_replay.py). A fallback whose `after` the plugin's version has passed is a note, never a
finding: the release lints its own folded tree. Prints one line per finding and per note, exits 1
on any finding and 2 on a wrong command line.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass
from typing import Dict, List, Mapping, Optional, Sequence, Tuple, Union

_TOOLS_LIBRARY = os.path.dirname(os.path.abspath(__file__))
_CHECKOUT = os.path.dirname(os.path.dirname(_TOOLS_LIBRARY))
sys.path.insert(0, os.path.join(_CHECKOUT, "plugins", "flow", "scripts"))
sys.path.insert(0, os.path.join(_CHECKOUT, "plugins", "standards", "skills", "init", "scripts"))
sys.path.insert(0, _TOOLS_LIBRARY)

import _config_migration_steps as flow_reader  # noqa: E402
import config_migration_steps as standards_reader  # noqa: E402
from migration_replay import (  # noqa: E402
    Fallback,
    KeyList,
    mirror_findings,
    old_keys,
    replay,
    tie_findings,
)

_ENCODING = "utf-8"
_STEP_LIST = os.path.join("skills", "init", "migrations.json")
_MANIFEST = "plugin.source.json"
_MIRROR = os.path.join("tools", "config-keys", "flow-schema.txt")
_BASELINE = os.path.join("tools", "config-keys", "flow-baseline.txt")
_DEPRECATED_MARK = " deprecated"
_HEADER_MARK = "#"
_STEP_NAME = re.compile(r"^[a-z]+(?:-[a-z]+)*$")
_VERSION = re.compile(r"^\d+\.\d+\.\d+$")
_VERSION_SEPARATOR = "."
_FLOW = "flow"
_STANDARDS = "standards"
_PASSED = 0
_FOUND = 1
_USAGE = 2
_ROOT_ARGUMENTS = 2

TypedStep = Union[flow_reader.Step, standards_reader.AddInEachStep]


@dataclass(frozen=True)
class Lint:
    findings: Tuple[str, ...]
    notes: Tuple[str, ...]


def _version(text: object) -> Optional[Tuple[int, ...]]:
    if not isinstance(text, str) or not _VERSION.match(text):
        return None
    return tuple(int(part) for part in text.split(_VERSION_SEPARATOR))


def _fallback(raw: object) -> Optional[Fallback]:
    if not isinstance(raw, dict):
        return None
    after = _version(raw.get("after"))
    files = raw.get("files")
    if after is None or not isinstance(files, list) or not files:
        return None
    if not all(isinstance(file, str) and file for file in files):
        return None
    return Fallback(after, tuple(files))


def _read_json(path: str) -> Optional[object]:
    try:
        with open(path, encoding=_ENCODING) as source:
            return json.load(source)
    except (OSError, ValueError):
        return None


def _raw_steps(path: str) -> Sequence[object]:
    listed = _read_json(path)
    steps = listed.get("steps") if isinstance(listed, dict) else None
    return steps if isinstance(steps, list) else ()


def _step_findings(raw: Mapping[str, object], label: str) -> Tuple[str, ...]:
    name = raw.get("name")
    reason = raw.get("reason")
    findings: List[str] = []
    if not isinstance(name, str) or not _STEP_NAME.match(name):
        findings.append(
            "%s: the step name %s is not lowercase words joined by hyphens" % (label, name)
        )
    if not isinstance(reason, str) or not reason.strip():
        findings.append("%s: the step %s has no reason" % (label, name))
    if "fallback" in raw and _fallback(raw["fallback"]) is None:
        findings.append(
            "%s: the fallback of the step %s needs an after version x.y.z and a list of files"
            % (label, name)
        )
    return tuple(findings)


def _shape_findings(raw_steps: Sequence[object], label: str) -> Tuple[str, ...]:
    steps = [raw for raw in raw_steps if isinstance(raw, dict)]
    names = [raw.get("name") for raw in steps]
    twice = sorted({str(name) for name in names if names.count(name) > 1})
    return tuple(finding for raw in steps for finding in _step_findings(raw, label)) + tuple(
        "%s: two steps are named %s" % (label, name) for name in twice
    )


def _fallbacks(raw_steps: Sequence[object]) -> Dict[str, Fallback]:
    fallbacks: Dict[str, Fallback] = {}
    for raw in raw_steps:
        fallback = _fallback(raw.get("fallback")) if isinstance(raw, dict) else None
        if fallback is not None:
            fallbacks[str(raw.get("name"))] = fallback
    return fallbacks


def _key(line: str) -> str:
    return line[: -len(_DEPRECATED_MARK)] if line.endswith(_DEPRECATED_MARK) else line


def _key_list(path: str) -> Optional[KeyList]:
    try:
        with open(path, encoding=_ENCODING) as source:
            lines = [line.strip() for line in source]
    except OSError:
        return None
    entries = [line for line in lines if line and not line.startswith(_HEADER_MARK)]
    keys = frozenset(_key(line) for line in entries)
    deprecated = frozenset(_key(line) for line in entries if line.endswith(_DEPRECATED_MARK))
    return KeyList(keys, deprecated)


def _notes(
    version: Optional[Tuple[int, ...]], fallbacks: Mapping[str, Fallback]
) -> Tuple[str, ...]:
    if version is None:
        return ()
    return tuple(
        "note: the %s fallback shipped; take it out before the next release (%s)"
        % (name, ", ".join(fallback.files))
        for name, fallback in fallbacks.items()
        if version > fallback.after
    )


def _typed_steps(path: str, plugin: str, label: str) -> Union[Tuple[TypedStep, ...], str]:
    reader = flow_reader if plugin == _FLOW else standards_reader
    typed = reader.read_steps(path)
    if isinstance(typed, (flow_reader.Problem, standards_reader.Problem)):
        reason = typed.reason.replace(path, label)
        return reason if label in reason else "%s: %s" % (label, reason)
    return tuple(typed)


def _schema_findings(
    root: str, typed: Sequence[flow_reader.Step], fallbacks: Mapping[str, Fallback]
) -> Tuple[str, ...]:
    mirror = _key_list(os.path.join(root, _MIRROR))
    baseline = _key_list(os.path.join(root, _BASELINE))
    if mirror is None or baseline is None:
        return ("cannot read %s or %s" % (_MIRROR, _BASELINE),)
    replayed = replay(baseline.keys, typed)
    return replayed.findings + mirror_findings(mirror, replayed, fallbacks, _MIRROR)


def _plugin_lint(root: str, plugin: str) -> Lint:
    plugin_root = os.path.join(root, "plugins", plugin)
    step_list = os.path.join(plugin_root, _STEP_LIST)
    label = os.path.relpath(step_list, root)
    raw_steps = _raw_steps(step_list)
    fallbacks = _fallbacks(raw_steps)
    typed = _typed_steps(step_list, plugin, label)
    if isinstance(typed, str):
        return Lint(_shape_findings(raw_steps, label) + (typed,), ())
    retiring: Dict[str, Tuple[str, ...]] = {}
    for step in typed:
        retiring[step.name] = retiring.get(step.name, ()) + old_keys(step)
    findings = _shape_findings(raw_steps, label) + tie_findings(retiring, fallbacks, plugin_root)
    if plugin == _FLOW:
        findings += _schema_findings(root, typed, fallbacks)
    manifest = _read_json(os.path.join(plugin_root, _MANIFEST))
    version = _version(manifest.get("version") if isinstance(manifest, dict) else None)
    return Lint(findings, _notes(version, fallbacks))


def lint(root: str) -> Lint:
    linted = [_plugin_lint(root, plugin) for plugin in (_FLOW, _STANDARDS)]
    return Lint(
        tuple(finding for plugin_lint in linted for finding in plugin_lint.findings),
        tuple(note for plugin_lint in linted for note in plugin_lint.notes),
    )


def main(arguments: Sequence[str]) -> int:
    if len(arguments) != _ROOT_ARGUMENTS:
        print("usage: migration_steps.py ROOT", file=sys.stderr)
        return _USAGE
    linted = lint(arguments[1])
    for line in linted.findings + linted.notes:
        print("lint: %s" % line)
    return _FOUND if linted.findings else _PASSED


if __name__ == "__main__":
    sys.exit(main(sys.argv))

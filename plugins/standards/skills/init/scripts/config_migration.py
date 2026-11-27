"""Standards' config migration: brings .standards/config.json to the plugin's step list. See
hooks/config_migration.sh, which init calls, and skills/init/migrations.json.

  config_migration.py plan  <step list> <config file> <new label>
  config_migration.py apply <step list> <config file> <new label> <out file>

Prints the label the file carries (its version, safe as a file name, or "unversioned"), then one
line per change: old key, new key, value and reason, split by tabs, "-" for none. Exit 0 when
nothing changes, 1 when something does (apply then writes the out file, with the config's mode), 2
when it cannot: the reason on stderr, nothing written. plan writes nothing at all.

What each step does is in config_migration_steps.py; a step looks only at the file, so a second run
changes nothing. The label becomes the new label when a step changed the file, never otherwise. The written file keeps the key order, the indent unit of
its first indented line (none for a one-line file) and its final newline, and non-ASCII text stays
raw when the file held it raw.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple, Union

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import config_migration_steps  # noqa: E402
from config_migration_steps import NONE, AddInEachStep, Change, Problem, Stepped  # noqa: E402

_NOTHING_TO_CHANGE = 0
_CHANGED = 1
_CANNOT = 2
_PLAN = "plan"
_APPLY = "apply"
_PLAN_ARGUMENT_COUNT = 4
_APPLY_ARGUMENT_COUNT = 5
_USAGE = (
    "usage: config_migration.py plan <step list> <config file> <new label>\n"
    "       config_migration.py apply <step list> <config file> <new label> <out file>"
)
_LABEL_KEY = "version"
_LABEL_REASON = "the standards version that last migrated this file"
_UNVERSIONED = "unversioned"
_NOT_IN_A_FILE_NAME = re.compile(r"[^A-Za-z0-9._-]+")
_LABEL_LENGTH_CAP = 64
_ENCODING = "utf-8"
_NEWLINE = "\n"
_FIRST_INDENT = re.compile(r"\n([ \t]+)\S")


@dataclass(frozen=True)
class Layout:
    indent: Optional[str]
    escapes_non_ascii: bool
    ending: str


@dataclass(frozen=True)
class Migration:
    label_found: str
    text: str
    changes: Tuple[Change, ...]


@dataclass(frozen=True)
class Invocation:
    command: str
    step_list: str
    config_file: str
    new_label: str
    out_file: str


def _invocation(arguments: List[str]) -> Optional[Invocation]:
    if len(arguments) == _PLAN_ARGUMENT_COUNT and arguments[0] == _PLAN:
        return Invocation(arguments[0], arguments[1], arguments[2], arguments[3], "")
    if len(arguments) == _APPLY_ARGUMENT_COUNT and arguments[0] == _APPLY:
        return Invocation(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4])
    return None


def _label(config: Dict[str, Any]) -> str:
    found = config.get(_LABEL_KEY)
    text = found if isinstance(found, str) else ""
    safe = _NOT_IN_A_FILE_NAME.sub("-", text)[:_LABEL_LENGTH_CAP].strip(".-")
    return safe or _UNVERSIONED


def _labelled(stepped: Stepped, new_label: str) -> Stepped:
    if not stepped.changes or stepped.config.get(_LABEL_KEY) == new_label:
        return stepped
    old_key = _LABEL_KEY if _LABEL_KEY in stepped.config else NONE
    label_change = Change(old_key, _LABEL_KEY, new_label, _LABEL_REASON)
    return Stepped({**stepped.config, _LABEL_KEY: new_label}, stepped.changes + (label_change,))


def _layout(text: str) -> Layout:
    first_indent = _FIRST_INDENT.search(text)
    indent = first_indent.group(1) if first_indent else None
    return Layout(indent, text.isascii(), _NEWLINE if text.endswith(_NEWLINE) else "")


def _rendered(config: Dict[str, Any], layout: Layout) -> str:
    text = json.dumps(config, indent=layout.indent, ensure_ascii=layout.escapes_non_ascii)
    return text + layout.ending


def _migration(
    text: str, steps: Tuple[AddInEachStep, ...], new_label: str
) -> Union[Migration, Problem]:
    try:
        config = json.loads(text)
    except ValueError as error:
        return Problem("it is not JSON: %s" % error)
    if not isinstance(config, dict):
        return Problem("it is not a JSON object")
    stepped = config_migration_steps.stepped(config, steps)
    if isinstance(stepped, Problem):
        return stepped
    labelled = _labelled(stepped, new_label)
    if not labelled.changes:
        return Migration(_label(config), text, ())
    return Migration(_label(config), _rendered(labelled.config, _layout(text)), labelled.changes)


def _config_text(config_file: str) -> Union[str, Problem]:
    try:
        with open(config_file, encoding=_ENCODING, newline="") as config:
            return config.read()
    except (OSError, UnicodeDecodeError) as error:
        return Problem("cannot read it: %s" % error)


def _written_problem(config_file: str, out_file: str, text: str) -> Optional[Problem]:
    folder = os.path.dirname(os.path.abspath(out_file))
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding=_ENCODING, newline="", dir=folder, delete=False
        ) as partial:
            partial.write(text)
        shutil.copymode(config_file, partial.name)
        os.replace(partial.name, out_file)
    except OSError as error:
        return Problem("cannot write %s: %s" % (out_file, error))
    return None


def _migrated(invocation: Invocation) -> Union[Migration, Problem]:
    if not invocation.new_label or _NOT_IN_A_FILE_NAME.search(invocation.new_label):
        return Problem("the new label %r is not a version" % invocation.new_label)
    steps = config_migration_steps.read_steps(invocation.step_list)
    if isinstance(steps, Problem):
        return steps
    text = _config_text(invocation.config_file)
    if isinstance(text, Problem):
        return text
    return _migration(text, steps, invocation.new_label)


def _migrated_and_written(invocation: Invocation) -> Union[Migration, Problem]:
    migration = _migrated(invocation)
    if isinstance(migration, Problem) or not migration.changes or invocation.command != _APPLY:
        return migration
    problem = _written_problem(invocation.config_file, invocation.out_file, migration.text)
    return migration if problem is None else problem


def main() -> int:
    invocation = _invocation(sys.argv[1:])
    if invocation is None:
        print(_USAGE, file=sys.stderr)
        return _CANNOT
    migration = _migrated_and_written(invocation)
    if isinstance(migration, Problem):
        print("%s: %s" % (invocation.config_file, migration.reason), file=sys.stderr)
        return _CANNOT
    print(migration.label_found)
    for change in migration.changes:
        print(change.line())
    return _CHANGED if migration.changes else _NOTHING_TO_CHANGE


if __name__ == "__main__":
    sys.exit(main())

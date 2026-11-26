"""Flow's config migration: brings .flow/config.yaml to the plugin's step list. See
lib/config_migration.sh, which init calls, and skills/init/migrations.json.

  _config_migration.py plan  <step list> <config file> <new label>
  _config_migration.py apply <step list> <config file> <new label> <out file>

Prints the label the file carries (its config_version, safe as a file name, or "unversioned"), then
one line per change: old key, new key, value and reason, split by tabs, "-" for none. Exit 0 when
nothing changes, 1 when something does (apply then writes the out file, with the config's mode), 2
when it cannot: the reason and the line on stderr, nothing written. plan writes nothing at all.

A step looks only at the file, so a second run changes nothing: remove takes a key's block out
when the key is there, add writes `key: value  # comment` when it is not, known changes nothing.
The label becomes the new label when a step changed the file or the file has none, never
otherwise. The helper reads its own result again before it writes: a key no step named that lost
or changed its value, or a step's key that does not read as the step says, is exit 2.
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from typing import List, Optional, Tuple, Union

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _config_migration_steps  # noqa: E402
import _config_yaml  # noqa: E402
import _config_yaml_edits  # noqa: E402
from _config_migration_steps import AddStep, KnownStep, Problem, RemoveStep, Step  # noqa: E402

_NOTHING_TO_CHANGE = 0
_CHANGED = 1
_CANNOT = 2
_PLAN = "plan"
_APPLY = "apply"
_PLAN_ARGUMENT_COUNT = 4
_APPLY_ARGUMENT_COUNT = 5
_USAGE = (
    "usage: _config_migration.py plan <step list> <config file> <new label>\n"
    "       _config_migration.py apply <step list> <config file> <new label> <out file>"
)
_LABEL_KEY = "config_version"
_LABEL_REASON = "the flow version that last migrated this file"
_LABEL_COMMENT = "# the flow version that last migrated this file; init keeps it"
_UNVERSIONED = "unversioned"
_NOT_IN_A_FILE_NAME = re.compile(r"[^A-Za-z0-9._-]+")
_LABEL_LENGTH_CAP = 64
_NONE = "-"
_FIELD_SEPARATOR = "\t"
_LINE_BREAKS = re.compile(r"[\t\r\n]")
_ENCODING = "utf-8"


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
class Stepped:
    document: _config_yaml.Document
    changes: Tuple[Change, ...]


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


def _report_value(items: Tuple[str, ...]) -> str:
    if not items:
        return _NONE
    shown = items[0] if len(items) == 1 else "[" + ", ".join(items) + "]"
    return _LINE_BREAKS.sub(" ", shown)


def _label(document: _config_yaml.Document) -> str:
    found = ",".join(_config_yaml.values(document, _LABEL_KEY))
    safe = _NOT_IN_A_FILE_NAME.sub("-", found)[:_LABEL_LENGTH_CAP].strip(".-")
    return safe or _UNVERSIONED


def _edit(document: _config_yaml.Document, step: Step) -> Edit:
    unchanged = Edit(_config_yaml.render(document), ())
    if isinstance(step, KnownStep):
        return unchanged
    present = _config_yaml.has_key(document, step.key)
    if isinstance(step, RemoveStep):
        if not present:
            return unchanged
        old_value = _report_value(_config_yaml.values(document, step.key))
        text = _config_yaml_edits.without_key(document, step.key)
        return Edit(text, (Change(step.key, _NONE, old_value, step.reason),))
    if present:
        return unchanged
    text = _config_yaml_edits.with_key(document, step.key, step.value_text, step.comment)
    new_value = _report_value(_config_yaml.value_items(step.value_text))
    return Edit(text, (Change(_NONE, step.key, new_value, step.reason),))


def _labelled(document: _config_yaml.Document, new_label: str, changed: bool) -> Edit:
    unchanged = Edit(_config_yaml.render(document), ())
    label_change = Change(_LABEL_KEY, _LABEL_KEY, new_label, _LABEL_REASON)
    if not _config_yaml.has_key(document, _LABEL_KEY):
        text = _config_yaml_edits.with_key(document, _LABEL_KEY, new_label, _LABEL_COMMENT)
        return Edit(text, (Change(_NONE, _LABEL_KEY, new_label, _LABEL_REASON),))
    if not changed or _config_yaml.values(document, _LABEL_KEY) == (new_label,):
        return unchanged
    return Edit(_config_yaml_edits.with_value(document, _LABEL_KEY, new_label), (label_change,))


def _reparsed(text: str, newline: str, after: str) -> Union[_config_yaml.Document, Problem]:
    document = _config_yaml.parse(text, newline)
    if isinstance(document, _config_yaml.Refusal):
        reason = "line %d: %s" % (document.line_number, document.reason)
        return Problem(
            "%s left the file outside the subset (%s); nothing written" % (after, reason)
        )
    return document


def _named(path: str, named_keys: Tuple[str, ...]) -> bool:
    return any(
        path == key or path.startswith(key + ".") or key.startswith(path + ".")
        for key in named_keys
    )


def _expected(step: Step, before: _config_yaml.Document) -> Tuple[str, ...]:
    if isinstance(step, AddStep) and not _config_yaml.has_key(before, step.key):
        return _config_yaml.value_items(step.value_text)
    return () if isinstance(step, RemoveStep) else _config_yaml.values(before, step.key)


def _check_problem(
    before: _config_yaml.Document,
    after: _config_yaml.Document,
    steps: Tuple[Step, ...],
    new_label: str,
) -> Optional[Problem]:
    named_keys = tuple(step.key for step in steps) + (_LABEL_KEY,)
    before_keys = _config_yaml.key_paths(before)
    for path in before_keys + _config_yaml.key_paths(after):
        unnamed = not _named(path, named_keys)
        moved = _config_yaml.values(before, path) != _config_yaml.values(after, path)
        lost = _config_yaml.has_key(before, path) != _config_yaml.has_key(after, path)
        if unnamed and (moved or lost):
            return Problem("the migration would change %s, which no step names" % path)
    for step in steps:
        if _config_yaml.values(after, step.key) != _expected(step, before):
            return Problem("the step %s would not leave %s as it says" % (step.name, step.key))
    if _config_yaml.values(after, _LABEL_KEY) != (new_label,):
        return Problem("the migration would not leave %s at %s" % (_LABEL_KEY, new_label))
    return None


def _stepped(original: _config_yaml.Document, steps: Tuple[Step, ...]) -> Union[Stepped, Problem]:
    document = original
    changes: List[Change] = []
    for step in steps:
        edit = _edit(document, step)
        changes.extend(edit.changes)
        reparsed = _reparsed(edit.text, original.newline, "the step " + step.name)
        if isinstance(reparsed, Problem):
            return reparsed
        document = reparsed
    return Stepped(document, tuple(changes))


def _migration(text: str, steps: Tuple[Step, ...], new_label: str) -> Union[Migration, Problem]:
    original = _config_yaml.parse(text, _config_yaml.NEWLINE)
    if isinstance(original, _config_yaml.Refusal):
        return Problem("line %d: %s" % (original.line_number, original.reason))
    stepped = _stepped(original, steps)
    if isinstance(stepped, Problem):
        return stepped
    labelled = _labelled(stepped.document, new_label, bool(stepped.changes))
    changes = stepped.changes + labelled.changes
    label_found = _label(original)
    if not changes:
        return Migration(label_found, text, ())
    after = _reparsed(labelled.text, original.newline, "the label")
    if isinstance(after, Problem):
        return after
    problem = _check_problem(original, after, steps, new_label)
    if problem is not None:
        return Problem(problem.reason + "; nothing written")
    return Migration(label_found, labelled.text, changes)


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
    steps = _config_migration_steps.read_steps(invocation.step_list)
    if isinstance(steps, Problem):
        return steps
    text = _config_text(invocation.config_file)
    if isinstance(text, Problem):
        return text
    return _migration(text, steps, invocation.new_label)


def main() -> int:
    invocation = _invocation(sys.argv[1:])
    if invocation is None:
        print(_USAGE, file=sys.stderr)
        return _CANNOT
    migration = _migrated(invocation)
    if isinstance(migration, Problem):
        print("%s: %s" % (invocation.config_file, migration.reason), file=sys.stderr)
        return _CANNOT
    if migration.changes and invocation.command == _APPLY:
        problem = _written_problem(invocation.config_file, invocation.out_file, migration.text)
        if problem is not None:
            print("%s: %s" % (invocation.config_file, problem.reason), file=sys.stderr)
            return _CANNOT
    print(migration.label_found)
    for change in migration.changes:
        print(change.line())
    return _CHANGED if migration.changes else _NOTHING_TO_CHANGE


if __name__ == "__main__":
    sys.exit(main())

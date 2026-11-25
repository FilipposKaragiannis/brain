#!/usr/bin/env python3
"""Fail a change that alters what a plugin ships and adds no changelog fragment for that plugin.

Usage: python3 -I tools/lib/fragments_needed.py <ref>...   (run from the repository root)
The change is the non-merge commits reachable from HEAD and from none of the refs: give the PR
base and the default branch. The ref `unavailable`, which verify passes for a base it refused, is
dropped and the check compares with the refs left.
Prints one line per plugin that owes a fragment, and exits 1 when any owes, 0 when none does, and
2 when no ref is left or git cannot resolve one. The rule: docs/adr/0002-changelog-fragments.md.
Needs python3 >= 3.9 and nothing else.
"""

import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Optional, Sequence, Union

_GIT_TIMEOUT_SECONDS = 120
_GIT = "git"
_HEAD = "HEAD"
_UNAVAILABLE_BASE = "unavailable"
_PLUGINS_FOLDER = "plugins"
_PLUGIN_FOLDER = "plugins/%s/"
_PLUGIN_SOURCE = "plugins/*/plugin.source.json"
_FRAGMENT = "plugins/%s/changelog.d/*.md"
_FRAGMENT_TO_ADD = "plugins/%s/changelog.d/<slug>.md"
_FRAGMENT_FORMAT = "docs/adr/0002-changelog-fragments.md"
_EXEMPT = (
    "plugins/*/changelog.d/**",
    "plugins/*/CHANGELOG.md",
    "plugins/meta/skills/map/assets/map.html",
    "plugins/*/tests/**",
    "plugins/*/hooks/tests/**",
    "plugins/*/app/*/test/**",
    "plugins/*/evals/**",
)
_ANY_DEPTH = "**"
_ONE_SEGMENT_WILDCARD = "*"
_ANY_DEPTH_PATTERN = ".*"
_ONE_SEGMENT_PATTERN = "[^/]*"
_DELETED = "D"
_PLUGIN_NAME_SEGMENT = 1
_EXIT_NONE_OWED = 0
_EXIT_OWED = 1
_EXIT_REFUSED = 2


@dataclass(frozen=True)
class _Change:
    status: str
    path: str


@dataclass(frozen=True)
class _Finding:
    plugin: str
    first_file: str
    more_files: int


@dataclass(frozen=True)
class _Refusal:
    lines: "tuple[str, ...]"


@dataclass(frozen=True)
class _Comparison:
    commits: "tuple[str, ...]"
    notice: Optional[str]


@dataclass(frozen=True)
class _Work:
    changes: "tuple[_Change, ...]"
    paths_at_head: "frozenset[str]"
    paths_at_references: "frozenset[str]"


def _glob_pattern(glob: str) -> "re.Pattern[str]":
    segments = (
        _ANY_DEPTH_PATTERN
        if segment == _ANY_DEPTH
        else _ONE_SEGMENT_PATTERN.join(
            re.escape(text) for text in segment.split(_ONE_SEGMENT_WILDCARD)
        )
        for segment in glob.split("/")
    )
    return re.compile("/".join(segments))


def _matches(path: str, glob: str) -> bool:
    return _glob_pattern(glob).fullmatch(path) is not None


def _git_output(arguments: Sequence[str]) -> Optional[bytes]:
    try:
        completed = subprocess.run(  # noqa: S603
            (_GIT, *arguments), stdout=subprocess.PIPE, timeout=_GIT_TIMEOUT_SECONDS, check=False
        )
    except (subprocess.TimeoutExpired, OSError):
        return None
    return completed.stdout if completed.returncode == 0 else None


def _commit_of(reference: str) -> Optional[str]:
    output = _git_output(
        ("rev-parse", "--verify", "--quiet", "--end-of-options", reference + "^{commit}")
    )
    return None if output is None else output.decode().strip()


def _comparison(arguments: Sequence[str]) -> Union[_Comparison, _Refusal]:
    references = tuple(argument for argument in arguments if argument != _UNAVAILABLE_BASE)
    if not references:
        return _Refusal(
            ("fragments: no ref to compare with; give the PR base and the default branch",)
        )
    commits = tuple(_commit_of(reference) for reference in references)
    unknown = tuple(reference for reference, commit in zip(references, commits) if commit is None)
    if unknown:
        return _Refusal(
            tuple(
                "fragments: git cannot resolve %s to a commit" % reference for reference in unknown
            )
        )
    notice = None
    if len(references) < len(arguments):
        notice = "fragments: no comparison base given, comparing with %s" % ", ".join(references)
    return _Comparison(tuple(commit for commit in commits if commit is not None), notice)


def _fields(output: bytes) -> "list[str]":
    return [os.fsdecode(field) for field in output.split(b"\0") if field]


def _changes(output: bytes) -> "tuple[_Change, ...]":
    fields = iter(_fields(output))
    return tuple(_Change(status, path) for status, path in zip(fields, fields))


def _plugin_paths_at(commit: str) -> Union["frozenset[str]", _Refusal]:
    tree = _git_output(("ls-tree", "-r", "-z", "--name-only", commit, "--", _PLUGINS_FOLDER))
    if tree is None:
        return _Refusal(("fragments: git could not list the plugins at %s" % commit,))
    return frozenset(_fields(tree))


def _unlisted(commits: "tuple[str, ...]") -> _Refusal:
    return _Refusal(("fragments: git could not list the commits since %s" % ", ".join(commits),))


def _work(commits: "tuple[str, ...]") -> Union[_Work, _Refusal]:
    log = _git_output(
        (
            "log",
            "--no-merges",
            "--no-renames",
            "-z",
            "--name-status",
            "--format=",
            _HEAD,
            "--not",
            *commits,
        )
    )
    paths_at_head = _plugin_paths_at(_HEAD)
    if log is None or isinstance(paths_at_head, _Refusal):
        return _unlisted(commits)
    paths_at_references: "set[str]" = set()
    for commit in commits:
        paths = _plugin_paths_at(commit)
        if isinstance(paths, _Refusal):
            return _unlisted(commits)
        paths_at_references |= paths
    return _Work(_changes(log), paths_at_head, frozenset(paths_at_references))


def _plugins(paths_at_head: "frozenset[str]") -> "list[str]":
    return sorted(
        path.split("/")[_PLUGIN_NAME_SEGMENT]
        for path in paths_at_head
        if _matches(path, _PLUGIN_SOURCE)
    )


def _releases(fragment_changes: "list[_Change]", paths_at_references: "frozenset[str]") -> bool:
    return any(
        change.status == _DELETED and change.path in paths_at_references
        for change in fragment_changes
    )


def _pays(fragment_changes: "list[_Change]", work: _Work) -> bool:
    return any(
        change.path in work.paths_at_head and change.path not in work.paths_at_references
        for change in fragment_changes
    )


def _shipped(changes: "list[_Change]") -> "list[str]":
    return sorted(
        {
            change.path
            for change in changes
            if not any(_matches(change.path, glob) for glob in _EXEMPT)
        }
    )


def _finding(plugin: str, work: _Work) -> Optional[_Finding]:
    plugin_changes = [
        change for change in work.changes if change.path.startswith(_PLUGIN_FOLDER % plugin)
    ]
    fragment_changes = [
        change for change in plugin_changes if _matches(change.path, _FRAGMENT % plugin)
    ]
    shipped = _shipped(plugin_changes)
    if (
        not shipped
        or _releases(fragment_changes, work.paths_at_references)
        or _pays(fragment_changes, work)
    ):
        return None
    return _Finding(plugin, shipped[0], len(shipped) - 1)


def _findings(work: _Work) -> "list[_Finding]":
    findings = (_finding(plugin, work) for plugin in _plugins(work.paths_at_head))
    return [finding for finding in findings if finding is not None]


def _message(finding: _Finding) -> str:
    more_files_note = ", and %d more" % finding.more_files if finding.more_files else ""
    return "fragments: %s changed (%s%s) with no fragment; add %s, format in %s" % (
        finding.plugin,
        finding.first_file,
        more_files_note,
        _FRAGMENT_TO_ADD % finding.plugin,
        _FRAGMENT_FORMAT,
    )


def main(arguments: Sequence[str]) -> int:
    comparison = _comparison(arguments)
    if isinstance(comparison, _Refusal):
        print("\n".join(comparison.lines), file=sys.stderr)
        return _EXIT_REFUSED
    if comparison.notice is not None:
        print(comparison.notice, file=sys.stderr)
    work = _work(comparison.commits)
    if isinstance(work, _Refusal):
        print("\n".join(work.lines), file=sys.stderr)
        return _EXIT_REFUSED
    findings = _findings(work)
    for finding in findings:
        print(_message(finding))
    return _EXIT_OWED if findings else _EXIT_NONE_OWED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""A tool's baseline file: a line of path, rule code and count, separated by tabs, per pair."""

from __future__ import annotations

import os
from typing import Dict, Sequence, Union

from lint_findings import (
    Failure,
    FindingCount,
    FindingCounts,
    Pair,
    ProjectPath,
    ProjectRoot,
    RuleCode,
    ToolName,
)

_BASELINE_FOLDER = "tools/lint-baseline"
_BASELINE_EXTENSION = ".tsv"
_BASELINE_SEPARATOR = "\t"
_BASELINE_LINE_FORMAT = "%s\t%s\t%d\n"
_BASELINE_FIELDS = 3
_STAGED_SUFFIX = ".tmp"
_FIRST_LINE_NUMBER = 1


def _baseline_path(root: ProjectRoot, tool: ToolName) -> str:
    return os.path.join(root.resolved_path, _BASELINE_FOLDER, tool.value + _BASELINE_EXTENSION)


def _parsed_baseline(path: str, lines: Sequence[str]) -> Union[FindingCounts, Failure]:
    counts: Dict[Pair, FindingCount] = {}
    for number, line in enumerate(lines, start=_FIRST_LINE_NUMBER):
        fields = line.split(_BASELINE_SEPARATOR)
        if len(fields) != _BASELINE_FIELDS or not fields[-1].isdigit():
            return Failure("%s line %d is not 'path<TAB>rule<TAB>count'" % (path, number))
        file_path, rule_code, count = fields
        counts[Pair(ProjectPath(file_path), RuleCode(rule_code))] = FindingCount(int(count))
    return FindingCounts(counts)


def read_baseline(root: ProjectRoot, tool: ToolName) -> Union[FindingCounts, Failure]:
    path = _baseline_path(root, tool)
    try:
        with open(path, encoding="utf-8") as baseline_file:
            lines = baseline_file.read().splitlines()
    except FileNotFoundError:
        return FindingCounts({})
    return _parsed_baseline(path, lines)


def write_baseline(root: ProjectRoot, tool: ToolName, counts: FindingCounts) -> None:
    path = _baseline_path(root, tool)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = "".join(
        _BASELINE_LINE_FORMAT % (pair.path.value, pair.code.value, counts.count_of(pair).value)
        for pair in counts.pairs()
    )
    staged_path = path + _STAGED_SUFFIX
    with open(staged_path, "w", encoding="utf-8") as baseline_file:
        baseline_file.write(text)
    os.replace(staged_path, path)

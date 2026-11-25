"""The findings a linter reports, and how many of them each file and rule holds."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass
from typing import Dict, Mapping, Sequence, Tuple, Union


@dataclass(frozen=True)
class ProjectRoot:
    resolved_path: str


@dataclass(frozen=True, order=True)
class ProjectPath:
    value: str


@dataclass(frozen=True)
class ToolName:
    value: str


@dataclass(frozen=True, order=True)
class RuleCode:
    value: str


@dataclass(frozen=True)
class LineNumber:
    value: int


@dataclass(frozen=True)
class FindingMessage:
    value: str


@dataclass(frozen=True, order=True)
class FindingCount:
    value: int


_NO_FINDINGS = FindingCount(0)


@dataclass(frozen=True, order=True)
class Pair:
    path: ProjectPath
    code: RuleCode


@dataclass(frozen=True)
class Finding:
    pair: Pair
    line: LineNumber
    message: FindingMessage


@dataclass(frozen=True)
class Failure:
    reason: str


LintResult = Union[Tuple[Finding, ...], Failure]


class FindingCounts:
    def __init__(self, counts: Mapping[Pair, FindingCount]) -> None:
        self._counts: Dict[Pair, FindingCount] = dict(counts)

    def count_of(self, pair: Pair) -> FindingCount:
        return self._counts.get(pair, _NO_FINDINGS)

    def pairs(self) -> Tuple[Pair, ...]:
        return tuple(sorted(self._counts))


def counts_of(findings: Sequence[Finding]) -> FindingCounts:
    tally = Counter(finding.pair for finding in findings)
    return FindingCounts({pair: FindingCount(count) for pair, count in tally.items()})

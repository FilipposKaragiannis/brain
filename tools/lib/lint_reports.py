"""A check holds each linter's findings against its baseline; an update records them instead."""

from __future__ import annotations

import enum
import os
import shutil
from dataclasses import dataclass
from typing import List, Mapping, Optional, Sequence, Tuple, Union

from lint_baseline_store import read_baseline, write_baseline
from lint_findings import (
    Failure,
    Finding,
    FindingCounts,
    LintResult,
    Pair,
    ProjectRoot,
    counts_of,
)
from lint_linters import Linter
from lint_project import Executable, Project, project_files

_LOCATIONS_SHOWN = 5
_UPDATE_INVOCATION = "python3 -I tools/lib/lint_baseline.py update"
_CI_VARIABLE = "CI"
_PATH_VARIABLE = "PATH"


class Verdict(enum.Enum):
    PASSED = "passed"
    FAILED = "failed"


class _RunPlace(enum.Enum):
    LOCAL = "local"
    CI = "ci"


@dataclass(frozen=True)
class ReportLine:
    text: str


@dataclass(frozen=True)
class Report:
    lines: Tuple[ReportLine, ...]
    verdict: Verdict


@dataclass(frozen=True)
class _RecordedFindings:
    linter: Linter
    findings: Tuple[Finding, ...]


def _report(lines: Sequence[str], verdict: Verdict) -> Report:
    return Report(tuple(ReportLine(line) for line in lines), verdict)


def _failed_report(line: str) -> Report:
    return _report((line,), Verdict.FAILED)


def _merged_reports(reports: Sequence[Report]) -> Report:
    lines = tuple(line for report in reports for line in report.lines)
    failed = any(report.verdict is Verdict.FAILED for report in reports)
    return Report(lines, Verdict.FAILED if failed else Verdict.PASSED)


def _grown_pairs(baseline: FindingCounts, current: FindingCounts) -> Tuple[Pair, ...]:
    return tuple(
        pair for pair in current.pairs() if current.count_of(pair) > baseline.count_of(pair)
    )


def _location_lines(located: Sequence[Finding]) -> Tuple[str, ...]:
    shown = [
        "  %s:%d: %s" % (finding.pair.path.value, finding.line.value, finding.message.value)
        for finding in located[:_LOCATIONS_SHOWN]
    ]
    hidden = len(located) - _LOCATIONS_SHOWN
    if hidden > 0:
        shown.append("  and %d more" % hidden)
    return tuple(shown)


def _growth_line(
    linter: Linter, pair: Pair, baseline: FindingCounts, current: FindingCounts
) -> str:
    return "lint: new %s finding %s in %s (baseline %d, now %d)" % (
        linter.name.value,
        pair.code.value,
        pair.path.value,
        baseline.count_of(pair).value,
        current.count_of(pair).value,
    )


def _new_finding_lines(
    linter: Linter, baseline: FindingCounts, current: FindingCounts, findings: Sequence[Finding]
) -> Tuple[str, ...]:
    lines: List[str] = []
    for pair in _grown_pairs(baseline, current):
        lines.append(_growth_line(linter, pair, baseline, current))
        lines.extend(_location_lines([finding for finding in findings if finding.pair == pair]))
    return tuple(lines)


def _fixed_lines(linter: Linter, baseline: FindingCounts, current: FindingCounts) -> Tuple[str, ...]:
    fixed = sum(
        max(0, baseline.count_of(pair).value - current.count_of(pair).value)
        for pair in baseline.pairs()
    )
    if not fixed:
        return ()
    return (
        "lint: %s has %d fewer findings than its baseline; run %s"
        % (linter.name.value, fixed, _UPDATE_INVOCATION),
    )


def _note_verdict(place: _RunPlace) -> Verdict:
    return Verdict.FAILED if place is _RunPlace.CI else Verdict.PASSED


def _run_place(environment: Mapping[str, str]) -> _RunPlace:
    return _RunPlace.CI if environment.get(_CI_VARIABLE) else _RunPlace.LOCAL


def _linter_executable(linter: Linter, environment: Mapping[str, str]) -> Optional[Executable]:
    found = shutil.which(linter.name.value, path=environment.get(_PATH_VARIABLE, os.defpath))
    return None if found is None else Executable(found)


def _missing_tool_report(linter: Linter, place: _RunPlace) -> Report:
    consequence = "; CI needs it" if place is _RunPlace.CI else ", so its check is skipped"
    line = "lint: %s is not installed%s. Install it: %s" % (
        linter.name.value,
        consequence,
        linter.install_hint.text,
    )
    return _report((line,), _note_verdict(place))


def _baseline_report(linter: Linter, baseline: FindingCounts, findings: Sequence[Finding]) -> Report:
    current = counts_of(findings)
    new_lines = _new_finding_lines(linter, baseline, current, findings)
    verdict = Verdict.FAILED if new_lines else Verdict.PASSED
    return _report(new_lines + _fixed_lines(linter, baseline, current), verdict)


def _version_report(
    linter: Linter, executable: Executable, root: ProjectRoot, place: _RunPlace
) -> Report:
    notes = linter.version_notes(executable, root)
    if not notes:
        return _report((), Verdict.PASSED)
    return _report(tuple("lint: " + note.text for note in notes), _note_verdict(place))


def _check_linter(
    linter: Linter, executable: Executable, project: Project, place: _RunPlace
) -> Report:
    findings = linter.findings(executable, project)
    if isinstance(findings, Failure):
        return _failed_report("lint: %s failed: %s" % (linter.name.value, findings.reason))
    recorded = read_baseline(project.root, linter.name)
    if isinstance(recorded, Failure):
        return _failed_report("lint: " + recorded.reason)
    return _merged_reports(
        (
            _baseline_report(linter, recorded, findings),
            _version_report(linter, executable, project.root, place),
        )
    )


def _linter_check(
    linter: Linter, project: Project, environment: Mapping[str, str], place: _RunPlace
) -> Report:
    executable = _linter_executable(linter, environment)
    if executable is None:
        return _missing_tool_report(linter, place)
    return _check_linter(linter, executable, project, place)


def run_check(
    root: ProjectRoot, environment: Mapping[str, str], linters: Tuple[Linter, ...]
) -> Report:
    project = project_files(root)
    if isinstance(project, Failure):
        return _failed_report("lint: cannot list the project files: " + project.reason)
    place = _run_place(environment)
    return _merged_reports(
        tuple(_linter_check(linter, project, environment, place) for linter in linters)
    )


def _findings_for_update(
    linter: Linter, project: Project, environment: Mapping[str, str]
) -> LintResult:
    executable = _linter_executable(linter, environment)
    if executable is None:
        return Failure(
            "lint: %s is not installed, so the baseline was not updated. Install it: %s"
            % (linter.name.value, linter.install_hint.text)
        )
    findings = linter.findings(executable, project)
    if isinstance(findings, Failure):
        return Failure(
            "lint: %s failed, so the baseline was not updated: %s"
            % (linter.name.value, findings.reason)
        )
    return findings


def _written_baselines(root: ProjectRoot, recorded: Sequence[_RecordedFindings]) -> Report:
    lines: List[str] = []
    for entry in recorded:
        counts = counts_of(entry.findings)
        write_baseline(root, entry.linter.name, counts)
        lines.append(
            "lint: %s baseline holds %d findings in %d pairs"
            % (entry.linter.name.value, len(entry.findings), len(counts.pairs()))
        )
    return _report(lines, Verdict.PASSED)


def _recorded_findings(
    project: Project, environment: Mapping[str, str], linters: Tuple[Linter, ...]
) -> Union[Tuple[_RecordedFindings, ...], Failure]:
    recorded: List[_RecordedFindings] = []
    for linter in linters:
        findings = _findings_for_update(linter, project, environment)
        if isinstance(findings, Failure):
            return findings
        recorded.append(_RecordedFindings(linter, findings))
    return tuple(recorded)


def run_update(
    root: ProjectRoot, environment: Mapping[str, str], linters: Tuple[Linter, ...]
) -> Report:
    project = project_files(root)
    if isinstance(project, Failure):
        return _failed_report("lint: cannot list the project files: " + project.reason)
    recorded = _recorded_findings(project, environment, linters)
    if isinstance(recorded, Failure):
        return _failed_report(recorded.reason)
    return _written_baselines(root, recorded)

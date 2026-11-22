#!/usr/bin/env python3
"""ShellCheck and Ruff findings, held against a recorded baseline.

The baseline is one file per tool in tools/lint-baseline/: a line of path, rule code and count,
separated by tabs. A finding is new when its (path, rule code) pair has more findings than the
baseline records, or is not recorded at all.

Usage: lint_baseline.py check [ROOT] [--shellcheck-chunks N]
         lint the shell and Python files git lists under ROOT (default: this repo), tracked or
         new and not ignored, and list every new finding. Exits 1 on any, and on a missing tool
         or a Ruff other than the pinned one when the CI variable is set.
       lint_baseline.py update [ROOT] [--shellcheck-chunks N]
         rewrite the baseline from today's findings.
--shellcheck-chunks N runs ShellCheck as N parallel processes (default: one per processor, up to
8); the findings do not depend on N. ShellCheck reports warnings and above. Needs python3 >= 3.9,
git, shellcheck and ruff.
"""

from __future__ import annotations

import argparse
import enum
import fnmatch
import functools
import json
import os
import shutil
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, Callable, Dict, List, Mapping, Optional, Sequence, Tuple, Union

REPOSITORY_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GIT_HOOK_PATTERN = "plugins/*/hooks/git/*"
GENERATED_RESULTS_FOLDER = "/evals/results/"
GIT_LIST_FILES = ("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard")
GIT_PATH_SEPARATOR = "\0"
BASELINE_FOLDER = "tools/lint-baseline"
BASELINE_EXTENSION = ".tsv"
BASELINE_SEPARATOR = "\t"
BASELINE_LINE_FORMAT = "%s\t%s\t%d\n"
BASELINE_FIELDS = 3
STAGED_SUFFIX = ".tmp"
FIRST_LINE_NUMBER = 1
RUFF_CONFIGURATION = "ruff.toml"
RUFF_PIN_FILE = "tools/requirements-lint.txt"
RUFF_PIN_PREFIX = "ruff=="
RUFF_VERSION_PREFIX = "ruff "
RUFF_SYNTAX_ERROR_CODE = "syntax-error"
UNKNOWN_VERSION = "(unknown version)"
COMMAND_TIMEOUT_SECONDS = 300
SHELLCHECK_SEVERITY = "warning"
SHELLCHECK_SOURCE_HANDLING = "--external-sources"
SHELLCHECK_FORMAT = "json1"
SHELLCHECK_RULE_CODE_FORMAT = "SC%d"
SHELLCHECK_MINIMUM_CHUNKS = 1
SHELLCHECK_MAXIMUM_CHUNKS = 8
SHELLCHECK_CHUNK_CHOICES = range(SHELLCHECK_MINIMUM_CHUNKS, SHELLCHECK_MAXIMUM_CHUNKS + 1)
LOCATIONS_SHOWN = 5
UPDATE_INVOCATION = "python3 -I tools/lib/lint_baseline.py update"
CI_VARIABLE = "CI"
PATH_VARIABLE = "PATH"
SUCCESS_EXIT_CODE = 0
FINDINGS_EXIT_CODE = 1
USAGE_EXIT_CODE = 2
GIT_SUCCESS_EXIT_CODES = (SUCCESS_EXIT_CODE,)
LINTER_SUCCESS_EXIT_CODES = (SUCCESS_EXIT_CODE, FINDINGS_EXIT_CODE)


class Command(enum.Enum):
    CHECK = "check"
    UPDATE = "update"


class Verdict(enum.Enum):
    PASSED = "passed"
    FAILED = "failed"


class RunPlace(enum.Enum):
    LOCAL = "local"
    CI = "ci"


@dataclass(frozen=True)
class ProjectRoot:
    resolved_path: str


@dataclass(frozen=True, order=True)
class ProjectPath:
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


@dataclass(frozen=True)
class ChunkCount:
    value: int


NO_FINDINGS = FindingCount(0)


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


@dataclass(frozen=True)
class CompletedCommand:
    exit_code: int
    output: str
    error_output: str


@dataclass(frozen=True)
class Project:
    root: ProjectRoot
    files: Tuple[ProjectPath, ...]


@dataclass(frozen=True)
class Report:
    lines: Tuple[str, ...]
    verdict: Verdict


LintResult = Union[Tuple[Finding, ...], Failure]


@dataclass(frozen=True)
class Linter:
    name: str
    install_hint: str
    select_files: Callable[[Tuple[ProjectPath, ...]], Tuple[ProjectPath, ...]]
    run: Callable[[str, ProjectRoot, Tuple[ProjectPath, ...]], LintResult]
    version_note: Callable[[str, ProjectRoot], Optional[str]]


@dataclass(frozen=True)
class RecordedFindings:
    linter: Linter
    findings: Tuple[Finding, ...]


@dataclass(frozen=True)
class Invocation:
    command: Command
    root: ProjectRoot
    shellcheck_chunks: ChunkCount


class FindingCounts:
    def __init__(self, counts: Mapping[Pair, FindingCount]) -> None:
        self._counts: Dict[Pair, FindingCount] = dict(counts)

    def count_of(self, pair: Pair) -> FindingCount:
        return self._counts.get(pair, NO_FINDINGS)

    def pairs(self) -> Tuple[Pair, ...]:
        return tuple(sorted(self._counts))


def run_command(command: Sequence[str], root: ProjectRoot) -> Union[CompletedCommand, Failure]:
    try:
        completed = subprocess.run(  # noqa: S603 - the command is built here from a resolved executable
            list(command),
            cwd=root.resolved_path,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return Failure("%s did not finish in %d seconds" % (command[0], COMMAND_TIMEOUT_SECONDS))
    except OSError as error:
        return Failure("%s did not start: %s" % (command[0], error))
    return CompletedCommand(completed.returncode, completed.stdout, completed.stderr.strip())


def checked_output(
    name: str, command: Sequence[str], root: ProjectRoot, success_codes: Tuple[int, ...]
) -> Union[str, Failure]:
    result = run_command(command, root)
    if isinstance(result, Failure):
        return result
    if result.error_output:
        return Failure(result.error_output)
    if result.exit_code not in success_codes:
        return Failure("%s exited %d: %s" % (name, result.exit_code, result.output))
    return result.output


def is_regular_file(root: ProjectRoot, path: str) -> bool:
    full_path = os.path.join(root.resolved_path, path)
    return os.path.isfile(full_path) and not os.path.islink(full_path)


def project_files(root: ProjectRoot) -> Union[Project, Failure]:
    output = checked_output("git ls-files", GIT_LIST_FILES, root, GIT_SUCCESS_EXIT_CODES)
    if isinstance(output, Failure):
        return output
    listed = sorted(path for path in output.split(GIT_PATH_SEPARATOR) if path)
    return Project(root, tuple(ProjectPath(path) for path in listed if is_regular_file(root, path)))


def is_git_hook(path: ProjectPath) -> bool:
    return fnmatch.fnmatchcase(path.value, GIT_HOOK_PATTERN)


def shell_files(files: Tuple[ProjectPath, ...]) -> Tuple[ProjectPath, ...]:
    return tuple(path for path in files if path.value.endswith(".sh") or is_git_hook(path))


def python_files(files: Tuple[ProjectPath, ...]) -> Tuple[ProjectPath, ...]:
    return tuple(
        path
        for path in files
        if path.value.endswith(".py") and GENERATED_RESULTS_FOLDER not in "/" + path.value
    )


def shellcheck_finding(comment: Mapping[str, Any]) -> Finding:
    return Finding(
        Pair(
            ProjectPath(comment["file"]),
            RuleCode(SHELLCHECK_RULE_CODE_FORMAT % comment["code"]),
        ),
        LineNumber(comment["line"]),
        FindingMessage(comment["message"]),
    )


def parsed_shellcheck_output(output: str) -> LintResult:
    try:
        return tuple(shellcheck_finding(comment) for comment in json.loads(output)["comments"])
    except (ValueError, KeyError, TypeError):
        return Failure("shellcheck printed output that is not its json1 format")


def shellcheck_chunk(
    executable: str, root: ProjectRoot, files: Tuple[ProjectPath, ...]
) -> LintResult:
    command = (
        executable,
        "--severity=" + SHELLCHECK_SEVERITY,
        SHELLCHECK_SOURCE_HANDLING,
        "--format=" + SHELLCHECK_FORMAT,
        "--",
        *(path.value for path in files),
    )
    output = checked_output("shellcheck", command, root, LINTER_SUCCESS_EXIT_CODES)
    if isinstance(output, Failure):
        return output
    return parsed_shellcheck_output(output)


def file_chunks(
    files: Tuple[ProjectPath, ...], chunk_count: ChunkCount
) -> Tuple[Tuple[ProjectPath, ...], ...]:
    ordered = tuple(sorted(files))
    used_chunks = min(chunk_count.value, len(ordered))
    return tuple(ordered[start::used_chunks] for start in range(used_chunks))


def merged_findings(results: Sequence[LintResult]) -> LintResult:
    findings: List[Finding] = []
    for result in results:
        if isinstance(result, Failure):
            return result
        findings.extend(result)
    return tuple(findings)


def shellcheck_run(
    chunk_count: ChunkCount, executable: str, root: ProjectRoot, files: Tuple[ProjectPath, ...]
) -> LintResult:
    chunks = file_chunks(files, chunk_count)
    if not chunks:
        return ()
    run_chunk = functools.partial(shellcheck_chunk, executable, root)
    with ThreadPoolExecutor(max_workers=len(chunks)) as pool:
        return merged_findings(tuple(pool.map(run_chunk, chunks)))


def no_version_note(executable: str, root: ProjectRoot) -> Optional[str]:
    return None


def pinned_ruff_version(root: ProjectRoot) -> Optional[str]:
    try:
        with open(os.path.join(root.resolved_path, RUFF_PIN_FILE), encoding="utf-8") as pin_file:
            lines = pin_file.read().splitlines()
    except OSError:
        return None
    pins = [
        line[len(RUFF_PIN_PREFIX) :].strip() for line in lines if line.startswith(RUFF_PIN_PREFIX)
    ]
    return pins[0] if pins else None


def installed_ruff_version(executable: str, root: ProjectRoot) -> str:
    result = run_command((executable, "--version"), root)
    if isinstance(result, Failure):
        return UNKNOWN_VERSION
    return result.output.strip().removeprefix(RUFF_VERSION_PREFIX) or UNKNOWN_VERSION


def ruff_version_note(executable: str, root: ProjectRoot) -> Optional[str]:
    pinned = pinned_ruff_version(root)
    if pinned is None:
        return None
    installed = installed_ruff_version(executable, root)
    if installed == pinned:
        return None
    return "ruff %s is installed but %s pins %s, so its findings may differ from the baseline" % (
        installed,
        RUFF_PIN_FILE,
        pinned,
    )


def project_relative_path(reported: str, root: ProjectRoot) -> ProjectPath:
    relative = os.path.relpath(os.path.realpath(reported), root.resolved_path)
    return ProjectPath(relative.replace(os.sep, "/"))


def ruff_finding(report: Mapping[str, Any], root: ProjectRoot) -> Finding:
    return Finding(
        Pair(
            project_relative_path(report["filename"], root),
            RuleCode(report["code"] or RUFF_SYNTAX_ERROR_CODE),
        ),
        LineNumber(report["location"]["row"]),
        FindingMessage(report["message"]),
    )


def parsed_ruff_output(output: str, root: ProjectRoot) -> LintResult:
    try:
        return tuple(ruff_finding(report, root) for report in json.loads(output))
    except (ValueError, KeyError, TypeError):
        return Failure("ruff printed output that is not its json format")


def ruff_run(executable: str, root: ProjectRoot, files: Tuple[ProjectPath, ...]) -> LintResult:
    if not files:
        return ()
    command = (
        executable,
        "check",
        "--no-cache",
        "--config",
        os.path.join(root.resolved_path, RUFF_CONFIGURATION),
        "--output-format",
        "json",
        "--",
        *(path.value for path in files),
    )
    output = checked_output("ruff", command, root, LINTER_SUCCESS_EXIT_CODES)
    if isinstance(output, Failure):
        return output
    return parsed_ruff_output(output, root)


def configured_linters(shellcheck_chunks: ChunkCount) -> Tuple[Linter, ...]:
    return (
        Linter(
            "shellcheck",
            "brew install shellcheck, or apt-get install shellcheck",
            shell_files,
            functools.partial(shellcheck_run, shellcheck_chunks),
            no_version_note,
        ),
        Linter(
            "ruff", "pip install -r " + RUFF_PIN_FILE, python_files, ruff_run, ruff_version_note
        ),
    )


def baseline_path(root: ProjectRoot, linter: Linter) -> str:
    return os.path.join(root.resolved_path, BASELINE_FOLDER, linter.name + BASELINE_EXTENSION)


def parsed_baseline(path: str, lines: Sequence[str]) -> Union[FindingCounts, Failure]:
    counts: Dict[Pair, FindingCount] = {}
    for number, line in enumerate(lines, start=FIRST_LINE_NUMBER):
        fields = line.split(BASELINE_SEPARATOR)
        if len(fields) != BASELINE_FIELDS or not fields[-1].isdigit():
            return Failure("%s line %d is not 'path<TAB>rule<TAB>count'" % (path, number))
        file_path, rule_code, count = fields
        counts[Pair(ProjectPath(file_path), RuleCode(rule_code))] = FindingCount(int(count))
    return FindingCounts(counts)


def read_baseline(path: str) -> Union[FindingCounts, Failure]:
    try:
        with open(path, encoding="utf-8") as baseline_file:
            lines = baseline_file.read().splitlines()
    except FileNotFoundError:
        return FindingCounts({})
    return parsed_baseline(path, lines)


def counts_of(findings: Sequence[Finding]) -> FindingCounts:
    tally = Counter(finding.pair for finding in findings)
    return FindingCounts({pair: FindingCount(count) for pair, count in tally.items()})


def write_baseline(path: str, counts: FindingCounts) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    text = "".join(
        BASELINE_LINE_FORMAT % (pair.path.value, pair.code.value, counts.count_of(pair).value)
        for pair in counts.pairs()
    )
    staged_path = path + STAGED_SUFFIX
    with open(staged_path, "w", encoding="utf-8") as baseline_file:
        baseline_file.write(text)
    os.replace(staged_path, path)


def grown_pairs(baseline: FindingCounts, current: FindingCounts) -> Tuple[Pair, ...]:
    return tuple(
        pair for pair in current.pairs() if current.count_of(pair) > baseline.count_of(pair)
    )


def location_lines(located: Sequence[Finding]) -> Tuple[str, ...]:
    shown = [
        "  %s:%d: %s" % (finding.pair.path.value, finding.line.value, finding.message.value)
        for finding in located[:LOCATIONS_SHOWN]
    ]
    hidden = len(located) - LOCATIONS_SHOWN
    if hidden > 0:
        shown.append("  and %d more" % hidden)
    return tuple(shown)


def growth_line(
    linter_name: str, pair: Pair, baseline: FindingCounts, current: FindingCounts
) -> str:
    return "lint: new %s finding %s in %s (baseline %d, now %d)" % (
        linter_name,
        pair.code.value,
        pair.path.value,
        baseline.count_of(pair).value,
        current.count_of(pair).value,
    )


def new_finding_lines(
    linter_name: str, baseline: FindingCounts, current: FindingCounts, findings: Sequence[Finding]
) -> Tuple[str, ...]:
    lines: List[str] = []
    for pair in grown_pairs(baseline, current):
        lines.append(growth_line(linter_name, pair, baseline, current))
        lines.extend(location_lines([finding for finding in findings if finding.pair == pair]))
    return tuple(lines)


def fixed_lines(
    linter_name: str, baseline: FindingCounts, current: FindingCounts
) -> Tuple[str, ...]:
    fixed = sum(
        max(0, baseline.count_of(pair).value - current.count_of(pair).value)
        for pair in baseline.pairs()
    )
    if not fixed:
        return ()
    return (
        "lint: %s has %d fewer findings than its baseline; run %s"
        % (linter_name, fixed, UPDATE_INVOCATION),
    )


def failed_report(line: str) -> Report:
    return Report((line,), Verdict.FAILED)


def merged_reports(reports: Sequence[Report]) -> Report:
    lines = tuple(line for report in reports for line in report.lines)
    failed = any(report.verdict is Verdict.FAILED for report in reports)
    return Report(lines, Verdict.FAILED if failed else Verdict.PASSED)


def note_verdict(place: RunPlace) -> Verdict:
    return Verdict.FAILED if place is RunPlace.CI else Verdict.PASSED


def run_place(environment: Mapping[str, str]) -> RunPlace:
    return RunPlace.CI if environment.get(CI_VARIABLE) else RunPlace.LOCAL


def linter_executable(linter: Linter, environment: Mapping[str, str]) -> Optional[str]:
    return shutil.which(linter.name, path=environment.get(PATH_VARIABLE, os.defpath))


def run_linter(linter: Linter, executable: str, project: Project) -> LintResult:
    return linter.run(executable, project.root, linter.select_files(project.files))


def missing_tool_report(linter: Linter, place: RunPlace) -> Report:
    consequence = "; CI needs it" if place is RunPlace.CI else ", so its check is skipped"
    line = "lint: %s is not installed%s. Install it: %s" % (
        linter.name,
        consequence,
        linter.install_hint,
    )
    return Report((line,), note_verdict(place))


def baseline_report(
    linter_name: str, baseline: FindingCounts, findings: Sequence[Finding]
) -> Report:
    current = counts_of(findings)
    new_lines = new_finding_lines(linter_name, baseline, current, findings)
    verdict = Verdict.FAILED if new_lines else Verdict.PASSED
    return Report(new_lines + fixed_lines(linter_name, baseline, current), verdict)


def version_report(linter: Linter, executable: str, root: ProjectRoot, place: RunPlace) -> Report:
    note = linter.version_note(executable, root)
    if note is None:
        return Report((), Verdict.PASSED)
    return Report(("lint: " + note,), note_verdict(place))


def check_linter(linter: Linter, executable: str, project: Project, place: RunPlace) -> Report:
    findings = run_linter(linter, executable, project)
    if isinstance(findings, Failure):
        return failed_report("lint: %s failed: %s" % (linter.name, findings.reason))
    recorded = read_baseline(baseline_path(project.root, linter))
    if isinstance(recorded, Failure):
        return failed_report("lint: " + recorded.reason)
    return merged_reports(
        (
            baseline_report(linter.name, recorded, findings),
            version_report(linter, executable, project.root, place),
        )
    )


def linter_check(
    linter: Linter, project: Project, environment: Mapping[str, str], place: RunPlace
) -> Report:
    executable = linter_executable(linter, environment)
    if executable is None:
        return missing_tool_report(linter, place)
    return check_linter(linter, executable, project, place)


def run_check(
    root: ProjectRoot, environment: Mapping[str, str], linters: Tuple[Linter, ...]
) -> Report:
    project = project_files(root)
    if isinstance(project, Failure):
        return failed_report("lint: cannot list the project files: " + project.reason)
    place = run_place(environment)
    return merged_reports(
        tuple(linter_check(linter, project, environment, place) for linter in linters)
    )


def findings_for_update(
    linter: Linter, project: Project, environment: Mapping[str, str]
) -> LintResult:
    executable = linter_executable(linter, environment)
    if executable is None:
        return Failure(
            "lint: %s is not installed, so the baseline was not updated. Install it: %s"
            % (linter.name, linter.install_hint)
        )
    findings = run_linter(linter, executable, project)
    if isinstance(findings, Failure):
        return Failure(
            "lint: %s failed, so the baseline was not updated: %s" % (linter.name, findings.reason)
        )
    return findings


def write_baselines(root: ProjectRoot, recorded: Sequence[RecordedFindings]) -> Report:
    lines: List[str] = []
    for entry in recorded:
        counts = counts_of(entry.findings)
        write_baseline(baseline_path(root, entry.linter), counts)
        lines.append(
            "lint: %s baseline holds %d findings in %d pairs"
            % (entry.linter.name, len(entry.findings), len(counts.pairs()))
        )
    return Report(tuple(lines), Verdict.PASSED)


def run_update(
    root: ProjectRoot, environment: Mapping[str, str], linters: Tuple[Linter, ...]
) -> Report:
    project = project_files(root)
    if isinstance(project, Failure):
        return failed_report("lint: cannot list the project files: " + project.reason)
    recorded: List[RecordedFindings] = []
    for linter in linters:
        findings = findings_for_update(linter, project, environment)
        if isinstance(findings, Failure):
            return failed_report(findings.reason)
        recorded.append(RecordedFindings(linter, findings))
    return write_baselines(root, recorded)


def root_problem(root: ProjectRoot) -> Optional[str]:
    if os.path.isfile(os.path.join(root.resolved_path, RUFF_CONFIGURATION)):
        return None
    return "%s is not a repository root: it holds no %s" % (root.resolved_path, RUFF_CONFIGURATION)


def parsed_invocation(
    arguments: List[str], repository_root: str, processor_count: int
) -> Invocation:
    parser = argparse.ArgumentParser(prog="lint_baseline.py")
    parser.add_argument("command", choices=[command.value for command in Command])
    parser.add_argument("root", nargs="?", default=repository_root)
    parser.add_argument(
        "--shellcheck-chunks", type=int, choices=SHELLCHECK_CHUNK_CHOICES, metavar="N"
    )
    parsed = parser.parse_args(arguments)
    default_chunks = min(processor_count, SHELLCHECK_MAXIMUM_CHUNKS)
    return Invocation(
        Command(parsed.command),
        ProjectRoot(os.path.realpath(parsed.root)),
        ChunkCount(parsed.shellcheck_chunks or default_chunks),
    )


def exit_code(verdict: Verdict) -> int:
    return FINDINGS_EXIT_CODE if verdict is Verdict.FAILED else SUCCESS_EXIT_CODE


def main(
    arguments: List[str], environment: Mapping[str, str], repository_root: str, processor_count: int
) -> int:
    invocation = parsed_invocation(arguments, repository_root, processor_count)
    problem = root_problem(invocation.root)
    if problem is not None:
        print("lint_baseline.py: " + problem, file=sys.stderr)
        return USAGE_EXIT_CODE
    linters = configured_linters(invocation.shellcheck_chunks)
    command_runner = run_check if invocation.command is Command.CHECK else run_update
    report = command_runner(invocation.root, environment, linters)
    for line in report.lines:
        print(line)
    return exit_code(report.verdict)


if __name__ == "__main__":
    sys.exit(
        main(sys.argv[1:], os.environ, REPOSITORY_ROOT, os.cpu_count() or SHELLCHECK_MINIMUM_CHUNKS)
    )

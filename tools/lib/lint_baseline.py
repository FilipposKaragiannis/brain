#!/usr/bin/env python3
"""ShellCheck and Ruff findings, held against a recorded baseline.

The baseline is one file per tool in tools/lint-baseline/: a line of path, rule code and count,
separated by tabs, so it survives a finding moving to another line. A finding is new when its
(path, rule code) pair has more findings than the baseline records, or is not recorded at all.

Usage: lint_baseline.py check [ROOT] [--shellcheck-chunks N]
         run both linters over the shell and Python files git lists under ROOT (default: this
         repo), tracked or new and not ignored, and list every new finding. Exits 1 on any, and
         on a missing tool when the CI variable is set.
       lint_baseline.py update [ROOT] [--shellcheck-chunks N]
         rewrite the baseline from today's findings, for when findings were fixed.
ShellCheck runs in parallel over a fixed split of the sorted files, each file in exactly one
chunk: N chunks, or by default one per processor up to SHELLCHECK_MAXIMUM_CHUNKS. It follows every
sourced file it can resolve (--external-sources), not only those in its own chunk, so the split
cannot change a finding. .shellcheckrc has no key for a severity floor, so the floor (warning) is
set here. Needs python3 >= 3.9, git, shellcheck and ruff.
"""

from __future__ import annotations

import argparse
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
from typing import Callable, Dict, List, Mapping, Tuple

REPOSITORY_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GIT_HOOK_PATTERN = "plugins/*/hooks/git/*"
GENERATED_RESULTS_FOLDER = "/evals/results/"
BASELINE_FOLDER = "tools/lint-baseline"
RUFF_CONFIGURATION = "ruff.toml"
RUFF_PIN_FILE = "tools/requirements-lint.txt"
RUFF_PIN_PREFIX = "ruff=="
COMMAND_TIMEOUT_SECONDS = 300
SHELLCHECK_SEVERITY = "warning"
SHELLCHECK_SOURCE_HANDLING = "--external-sources"
SHELLCHECK_MINIMUM_CHUNKS = 1
SHELLCHECK_MAXIMUM_CHUNKS = 8
SHELLCHECK_CHUNK_CHOICES = range(SHELLCHECK_MINIMUM_CHUNKS, SHELLCHECK_MAXIMUM_CHUNKS + 1)
LOCATIONS_SHOWN = 5
CHECK_COMMAND = "check"
UPDATE_COMMAND = "update"
UPDATE_INVOCATION = "python3 -I tools/lib/lint_baseline.py " + UPDATE_COMMAND
COMMANDS = (CHECK_COMMAND, UPDATE_COMMAND)
USAGE_EXIT_CODE = 2
FINDINGS_EXIT_CODE = 1
NO_EXIT_CODE = -1
LINTER_SUCCESS_EXIT_CODES = (0, 1)
BASELINE_FIELDS = 3


@dataclass(frozen=True, order=True)
class Pair:
    path: str
    code: str


@dataclass(frozen=True)
class Finding:
    path: str
    code: str
    line: int
    message: str

    def pair(self) -> Pair:
        return Pair(self.path, self.code)


@dataclass(frozen=True)
class CommandResult:
    exit_code: int
    output: str
    failure: str


@dataclass(frozen=True)
class Outcome:
    findings: List[Finding]
    failure: str
    version_mismatch: str


@dataclass(frozen=True)
class Linter:
    name: str
    install_hint: str
    select_files: Callable[[List[str]], List[str]]
    run: Callable[[str, str, List[str]], Outcome]


def run_command(command: List[str], working_folder: str) -> CommandResult:
    try:
        completed = subprocess.run(  # noqa: S603 - the command is built here from a resolved executable
            command,
            cwd=working_folder,
            capture_output=True,
            text=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return CommandResult(
            NO_EXIT_CODE,
            "",
            "%s did not finish in %d seconds" % (command[0], COMMAND_TIMEOUT_SECONDS),
        )
    except OSError as error:
        return CommandResult(NO_EXIT_CODE, "", "%s did not start: %s" % (command[0], error))
    return CommandResult(completed.returncode, completed.stdout, completed.stderr.strip())


@dataclass(frozen=True)
class Listing:
    files: List[str]
    failure: str


def is_regular_file(root: str, path: str) -> bool:
    full_path = os.path.join(root, path)
    return os.path.isfile(full_path) and not os.path.islink(full_path)


def project_files(root: str) -> Listing:
    result = run_command(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], root
    )
    if result.failure or result.exit_code != 0:
        return Listing([], result.failure or "git ls-files exited %d" % result.exit_code)
    paths = sorted(path for path in result.output.split("\0") if path)
    return Listing([path for path in paths if is_regular_file(root, path)], "")


def is_git_hook(path: str) -> bool:
    return fnmatch.fnmatchcase(path, GIT_HOOK_PATTERN)


def shell_files(files: List[str]) -> List[str]:
    return [path for path in files if path.endswith(".sh") or is_git_hook(path)]


def python_files(files: List[str]) -> List[str]:
    return [
        path
        for path in files
        if path.endswith(".py") and GENERATED_RESULTS_FOLDER not in "/" + path
    ]


def shellcheck_chunk_outcome(executable: str, root: str, files: List[str]) -> Outcome:
    command = [
        executable,
        "--severity=" + SHELLCHECK_SEVERITY,
        SHELLCHECK_SOURCE_HANDLING,
        "--format=json1",
        "--",
        *files,
    ]
    result = run_command(command, root)
    if result.failure or result.exit_code not in LINTER_SUCCESS_EXIT_CODES:
        return Outcome(
            [], result.failure or "shellcheck exited %d: %s" % (result.exit_code, result.output), ""
        )
    try:
        comments = json.loads(result.output)["comments"]
    except (ValueError, KeyError):
        return Outcome([], "shellcheck printed output that is not its json1 format", "")
    findings = [
        Finding(comment["file"], "SC%d" % comment["code"], comment["line"], comment["message"])
        for comment in comments
    ]
    return Outcome(findings, "", "")


def file_chunks(files: List[str], chunk_count: int) -> List[List[str]]:
    ordered = sorted(files)
    used_chunks = min(chunk_count, len(ordered))
    return [ordered[start::used_chunks] for start in range(used_chunks)]


def merged_outcome(outcomes: List[Outcome]) -> Outcome:
    failures = [outcome.failure for outcome in outcomes if outcome.failure]
    if failures:
        return Outcome([], failures[0], "")
    return Outcome([finding for outcome in outcomes for finding in outcome.findings], "", "")


def shellcheck_outcome(chunk_count: int, executable: str, root: str, files: List[str]) -> Outcome:
    chunks = file_chunks(files, chunk_count)
    if not chunks:
        return Outcome([], "", "")
    run_chunk = functools.partial(shellcheck_chunk_outcome, executable, root)
    with ThreadPoolExecutor(max_workers=len(chunks)) as pool:
        return merged_outcome(list(pool.map(run_chunk, chunks)))


def pinned_ruff_version(root: str) -> str:
    try:
        with open(os.path.join(root, RUFF_PIN_FILE), encoding="utf-8") as pin_file:
            lines = pin_file.read().splitlines()
    except OSError:
        return ""
    pins = [
        line[len(RUFF_PIN_PREFIX) :].strip() for line in lines if line.startswith(RUFF_PIN_PREFIX)
    ]
    return pins[0] if pins else ""


def ruff_version_mismatch(executable: str, root: str) -> str:
    pinned = pinned_ruff_version(root)
    if not pinned:
        return ""
    installed = run_command([executable, "--version"], root).output.strip().replace("ruff ", "")
    if installed == pinned:
        return ""
    return "ruff %s is installed but %s pins %s, so its findings may differ from the baseline" % (
        installed or "(unknown version)",
        RUFF_PIN_FILE,
        pinned,
    )


def ruff_outcome(executable: str, root: str, files: List[str]) -> Outcome:
    if not files:
        return Outcome([], "", "")
    ruff_configuration = os.path.join(root, RUFF_CONFIGURATION)
    command = [
        executable,
        "check",
        "--no-cache",
        "--config",
        ruff_configuration,
        "--output-format",
        "json",
        "--",
        *files,
    ]
    result = run_command(command, root)
    if result.failure or result.exit_code not in LINTER_SUCCESS_EXIT_CODES:
        return Outcome(
            [], result.failure or "ruff exited %d: %s" % (result.exit_code, result.output), ""
        )
    try:
        reports = json.loads(result.output)
    except ValueError:
        return Outcome([], "ruff printed output that is not json", "")
    real_root = os.path.realpath(root)
    findings = [
        Finding(
            os.path.relpath(os.path.realpath(report["filename"]), real_root).replace(os.sep, "/"),
            report["code"] or "syntax-error",
            report["location"]["row"],
            report["message"],
        )
        for report in reports
    ]
    return Outcome(findings, "", ruff_version_mismatch(executable, root))


def configured_linters(shellcheck_chunks: int) -> Tuple[Linter, ...]:
    return (
        Linter(
            "shellcheck",
            "brew install shellcheck, or apt-get install shellcheck",
            shell_files,
            functools.partial(shellcheck_outcome, shellcheck_chunks),
        ),
        Linter("ruff", "pip install -r " + RUFF_PIN_FILE, python_files, ruff_outcome),
    )


def baseline_path(root: str, linter: Linter) -> str:
    return os.path.join(root, BASELINE_FOLDER, linter.name + ".tsv")


@dataclass(frozen=True)
class BaselineRead:
    counts: Dict[Pair, int]
    problem: str


def read_baseline(path: str) -> BaselineRead:
    counts: Dict[Pair, int] = {}
    try:
        with open(path, encoding="utf-8") as baseline_file:
            lines = baseline_file.read().splitlines()
    except FileNotFoundError:
        return BaselineRead(counts, "")
    for number, line in enumerate(lines, start=1):
        fields = line.split("\t")
        if len(fields) != BASELINE_FIELDS or not fields[2].isdigit():
            return BaselineRead({}, "%s line %d is not 'path<TAB>rule<TAB>count'" % (path, number))
        counts[Pair(fields[0], fields[1])] = int(fields[2])
    return BaselineRead(counts, "")


def counts_of(findings: List[Finding]) -> Dict[Pair, int]:
    return dict(Counter(finding.pair() for finding in findings))


def write_baseline(path: str, counts: Dict[Pair, int]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = ["%s\t%s\t%d\n" % (pair.path, pair.code, counts[pair]) for pair in sorted(counts)]
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as baseline_file:
        baseline_file.write("".join(lines))
    os.replace(temporary, path)


def new_finding_lines(
    linter: Linter, baseline: Dict[Pair, int], findings: List[Finding]
) -> List[str]:
    lines: List[str] = []
    current = counts_of(findings)
    for pair in sorted(current):
        recorded = baseline.get(pair, 0)
        if current[pair] <= recorded:
            continue
        lines.append(
            "lint: new %s finding %s in %s (baseline %d, now %d)"
            % (linter.name, pair.code, pair.path, recorded, current[pair])
        )
        located = [finding for finding in findings if finding.pair() == pair]
        for finding in located[:LOCATIONS_SHOWN]:
            lines.append("  %s:%d: %s" % (finding.path, finding.line, finding.message))
        if len(located) > LOCATIONS_SHOWN:
            lines.append("  and %d more" % (len(located) - LOCATIONS_SHOWN))
    return lines


def fixed_count(baseline: Dict[Pair, int], findings: List[Finding]) -> int:
    current = counts_of(findings)
    return sum(max(0, recorded - current.get(pair, 0)) for pair, recorded in baseline.items())


@dataclass(frozen=True)
class Report:
    lines: List[str]
    failed: bool


def missing_tool(linter: Linter, in_ci: bool) -> Report:
    suffix = "; CI needs it" if in_ci else ", so its check is skipped"
    return Report(
        [
            "lint: %s is not installed%s. Install it: %s"
            % (linter.name, suffix, linter.install_hint)
        ],
        in_ci,
    )


def run_linter(linter: Linter, executable: str, root: str, files: List[str]) -> Outcome:
    return linter.run(executable, root, linter.select_files(files))


def check_linter(
    linter: Linter, root: str, executable: str, files: List[str], in_ci: bool
) -> Report:
    outcome = run_linter(linter, executable, root, files)
    if outcome.failure:
        return Report(["lint: %s failed: %s" % (linter.name, outcome.failure)], True)
    recorded = read_baseline(baseline_path(root, linter))
    if recorded.problem:
        return Report(["lint: " + recorded.problem], True)
    lines = new_finding_lines(linter, recorded.counts, outcome.findings)
    failed = bool(lines)
    fixed = fixed_count(recorded.counts, outcome.findings)
    if fixed:
        lines.append(
            "lint: %s has %d fewer findings than its baseline; run %s"
            % (linter.name, fixed, UPDATE_INVOCATION)
        )
    if outcome.version_mismatch:
        lines.append("lint: " + outcome.version_mismatch)
    return Report(lines, failed or (in_ci and bool(outcome.version_mismatch)))


def run_check(
    root: str, environment: Mapping[str, str], active_linters: Tuple[Linter, ...]
) -> Report:
    listing = project_files(root)
    if listing.failure:
        return Report(["lint: cannot list the project files: " + listing.failure], True)
    in_ci = bool(environment.get("CI"))
    lines: List[str] = []
    failed = False
    for linter in active_linters:
        executable = shutil.which(linter.name, path=environment.get("PATH", os.defpath))
        report = (
            check_linter(linter, root, executable, listing.files, in_ci)
            if executable
            else missing_tool(linter, in_ci)
        )
        lines.extend(report.lines)
        failed = failed or report.failed
    return Report(lines, failed)


def run_update(
    root: str, environment: Mapping[str, str], active_linters: Tuple[Linter, ...]
) -> Report:
    listing = project_files(root)
    if listing.failure:
        return Report(["lint: cannot list the project files: " + listing.failure], True)
    lines: List[str] = []
    recorded: Dict[str, Dict[Pair, int]] = {}
    for linter in active_linters:
        executable = shutil.which(linter.name, path=environment.get("PATH", os.defpath))
        if not executable:
            return Report(
                [
                    "lint: %s is not installed, so the baseline was not updated. Install it: %s"
                    % (linter.name, linter.install_hint)
                ],
                True,
            )
        outcome = run_linter(linter, executable, root, listing.files)
        if outcome.failure:
            return Report(
                [
                    "lint: %s failed, so the baseline was not updated: %s"
                    % (linter.name, outcome.failure)
                ],
                True,
            )
        recorded[linter.name] = counts_of(outcome.findings)
        lines.append(
            "lint: %s baseline holds %d findings in %d pairs"
            % (linter.name, len(outcome.findings), len(recorded[linter.name]))
        )
    for linter in active_linters:
        write_baseline(baseline_path(root, linter), recorded[linter.name])
    return Report(lines, False)


def root_problem(root: str) -> str:
    if not os.path.isfile(os.path.join(root, RUFF_CONFIGURATION)):
        return "%s is not a repository root: it holds no %s" % (root, RUFF_CONFIGURATION)
    return ""


@dataclass(frozen=True)
class Invocation:
    command: str
    root: str
    shellcheck_chunks: int


def parsed_invocation(
    arguments: List[str], repository_root: str, processor_count: int
) -> Invocation:
    parser = argparse.ArgumentParser(prog="lint_baseline.py")
    parser.add_argument("command", choices=COMMANDS)
    parser.add_argument("root", nargs="?", default=repository_root)
    parser.add_argument(
        "--shellcheck-chunks", type=int, choices=SHELLCHECK_CHUNK_CHOICES, metavar="N"
    )
    parsed = parser.parse_args(arguments)
    default_chunks = min(processor_count, SHELLCHECK_MAXIMUM_CHUNKS)
    return Invocation(parsed.command, parsed.root, parsed.shellcheck_chunks or default_chunks)


def main(
    arguments: List[str], environment: Mapping[str, str], repository_root: str, processor_count: int
) -> int:
    invocation = parsed_invocation(arguments, repository_root, processor_count)
    problem = root_problem(invocation.root)
    if problem:
        print("lint_baseline.py: " + problem, file=sys.stderr)
        return USAGE_EXIT_CODE
    active_linters = configured_linters(invocation.shellcheck_chunks)
    command_runner = run_check if invocation.command == CHECK_COMMAND else run_update
    report = command_runner(invocation.root, environment, active_linters)
    for line in report.lines:
        print(line)
    return FINDINGS_EXIT_CODE if report.failed else 0


if __name__ == "__main__":
    sys.exit(
        main(sys.argv[1:], os.environ, REPOSITORY_ROOT, os.cpu_count() or SHELLCHECK_MINIMUM_CHUNKS)
    )

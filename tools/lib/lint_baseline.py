#!/usr/bin/env python3
"""ShellCheck and Ruff findings, held against a recorded baseline.

The baseline is one file per tool in tools/lint-baseline/: a line of path, rule code and count,
separated by tabs, so it survives a finding moving to another line. A finding is new when its
(path, rule code) pair has more findings than the baseline records, or is not recorded at all.

Usage: lint_baseline.py check [ROOT]
         run both linters over the shell and Python files under ROOT/tools, ROOT/plugins and
         ROOT/shared (default: this repo) and list every new finding. Exits 1 on any, and on a
         missing tool when the CI variable is set.
       lint_baseline.py update [ROOT]
         rewrite the baseline from today's findings, for when findings were fixed.
Needs python3 >= 3.9, shellcheck and ruff.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Callable, Dict, List, Mapping

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SEARCHED_FOLDERS = ("tools", "plugins", "shared")
SKIPPED_FOLDERS = frozenset({"node_modules", "dist", ".git", "__pycache__"})
GENERATED_RESULTS_FOLDER = "/evals/results/"
BASELINE_FOLDER = "tools/lint-baseline"
RUFF_CONFIG = "ruff.toml"
RUFF_PIN_FILE = "tools/requirements-lint.txt"
RUFF_PIN_PREFIX = "ruff=="
COMMAND_TIMEOUT_SECONDS = 300
SHELLCHECK_PROCESSES = 4
SHELLCHECK_SEVERITY = "warning"
LOCATIONS_SHOWN = 5
CHECK_COMMAND = "check"
UPDATE_COMMAND = "update"
UPDATE_INVOCATION = "python3 -I tools/lib/lint_baseline.py " + UPDATE_COMMAND
USAGE_EXIT_CODE = 2
FINDINGS_EXIT_CODE = 1
BASELINE_FIELDS = 3


@dataclass(frozen=True)
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
            -1, "", "%s did not finish in %d seconds" % (command[0], COMMAND_TIMEOUT_SECONDS)
        )
    except OSError as error:
        return CommandResult(-1, "", "%s did not start: %s" % (command[0], error))
    return CommandResult(completed.returncode, completed.stdout, completed.stderr.strip())


def project_files(root: str) -> List[str]:
    found: List[str] = []
    for folder in SEARCHED_FOLDERS:
        for directory, subfolders, names in os.walk(os.path.join(root, folder)):
            subfolders[:] = sorted(name for name in subfolders if name not in SKIPPED_FOLDERS)
            for name in sorted(names):
                path = os.path.join(directory, name)
                if not os.path.islink(path):
                    found.append(os.path.relpath(path, root).replace(os.sep, "/"))
    return found


def is_git_hook(path: str) -> bool:
    parts = path.split("/")
    return len(parts) == 5 and parts[0] == "plugins" and parts[2:4] == ["hooks", "git"]


def shell_files(files: List[str]) -> List[str]:
    return [path for path in files if path.endswith(".sh") or is_git_hook(path)]


def python_files(files: List[str]) -> List[str]:
    return [
        path
        for path in files
        if path.endswith(".py") and GENERATED_RESULTS_FOLDER not in "/" + path
    ]


def balanced_chunks(root: str, files: List[str], count: int) -> List[List[str]]:
    chunks: List[List[str]] = [[] for _ in range(count)]
    loads = [0] * count
    by_size = sorted(
        files, key=lambda path: os.path.getsize(os.path.join(root, path)), reverse=True
    )
    for path in by_size:
        lightest = loads.index(min(loads))
        chunks[lightest].append(path)
        loads[lightest] += os.path.getsize(os.path.join(root, path))
    return [chunk for chunk in chunks if chunk]


def shellcheck_chunk(executable: str, root: str, files: List[str]) -> Outcome:
    command = [executable, "--severity=" + SHELLCHECK_SEVERITY, "--format=json1", "--", *files]
    result = run_command(command, root)
    if result.failure or result.exit_code not in (0, 1):
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


def shellcheck_outcome(executable: str, root: str, files: List[str]) -> Outcome:
    chunks = balanced_chunks(root, files, SHELLCHECK_PROCESSES)
    if not chunks:
        return Outcome([], "", "")
    with ThreadPoolExecutor(max_workers=len(chunks)) as pool:
        outcomes = list(pool.map(lambda chunk: shellcheck_chunk(executable, root, chunk), chunks))
    failures = [outcome.failure for outcome in outcomes if outcome.failure]
    findings = [finding for outcome in outcomes for finding in outcome.findings]
    return Outcome(findings, "; ".join(failures), "")


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
    config = os.path.join(root, RUFF_CONFIG)
    command = [
        executable,
        "check",
        "--no-cache",
        "--config",
        config,
        "--output-format",
        "json",
        "--",
        *files,
    ]
    result = run_command(command, root)
    if result.failure or result.exit_code not in (0, 1):
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


LINTERS = (
    Linter(
        "shellcheck",
        "brew install shellcheck, or apt-get install shellcheck",
        shell_files,
        shellcheck_outcome,
    ),
    Linter("ruff", "pip install -r " + RUFF_PIN_FILE, python_files, ruff_outcome),
)


def baseline_path(root: str, linter: Linter) -> str:
    return os.path.join(root, BASELINE_FOLDER, linter.name + ".tsv")


def read_baseline(path: str) -> Dict[Pair, int]:
    counts: Dict[Pair, int] = {}
    try:
        with open(path, encoding="utf-8") as baseline_file:
            lines = baseline_file.read().splitlines()
    except FileNotFoundError:
        return counts
    for number, line in enumerate(lines, start=1):
        fields = line.split("\t")
        if len(fields) != BASELINE_FIELDS or not fields[2].isdigit():
            raise ValueError("%s line %d is not 'path<TAB>rule<TAB>count'" % (path, number))
        counts[Pair(fields[0], fields[1])] = int(fields[2])
    return counts


def counts_of(findings: List[Finding]) -> Dict[Pair, int]:
    return dict(Counter(finding.pair() for finding in findings))


def write_baseline(path: str, counts: Dict[Pair, int]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [
        "%s\t%s\t%d\n" % (pair.path, pair.code, counts[pair])
        for pair in sorted(counts, key=lambda p: (p.path, p.code))
    ]
    temporary = path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as baseline_file:
        baseline_file.write("".join(lines))
    os.replace(temporary, path)


def new_finding_lines(
    linter: Linter, baseline: Dict[Pair, int], findings: List[Finding]
) -> List[str]:
    lines: List[str] = []
    current = counts_of(findings)
    for pair in sorted(current, key=lambda p: (p.path, p.code)):
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


def check_linter(linter: Linter, root: str, executable: str, in_ci: bool) -> Report:
    outcome = linter.run(executable, root, linter.select_files(project_files(root)))
    if outcome.failure:
        return Report(["lint: %s failed: %s" % (linter.name, outcome.failure)], True)
    baseline = read_baseline(baseline_path(root, linter))
    lines = new_finding_lines(linter, baseline, outcome.findings)
    failed = bool(lines)
    fixed = fixed_count(baseline, outcome.findings)
    if fixed:
        lines.append(
            "lint: %s has %d fewer findings than its baseline; run %s"
            % (linter.name, fixed, UPDATE_INVOCATION)
        )
    if outcome.version_mismatch:
        lines.append("lint: " + outcome.version_mismatch)
    return Report(lines, failed or (in_ci and bool(outcome.version_mismatch)))


def run_check(root: str, environment: Mapping[str, str]) -> Report:
    in_ci = bool(environment.get("CI"))
    lines: List[str] = []
    failed = False
    for linter in LINTERS:
        executable = shutil.which(linter.name, path=environment.get("PATH", os.defpath))
        report = (
            check_linter(linter, root, executable, in_ci)
            if executable
            else missing_tool(linter, in_ci)
        )
        lines.extend(report.lines)
        failed = failed or report.failed
    return Report(lines, failed)


def run_update(root: str, environment: Mapping[str, str]) -> Report:
    lines: List[str] = []
    recorded: Dict[str, Dict[Pair, int]] = {}
    for linter in LINTERS:
        executable = shutil.which(linter.name, path=environment.get("PATH", os.defpath))
        if not executable:
            return Report(
                [
                    "lint: %s is not installed, so the baseline was not updated. Install it: %s"
                    % (linter.name, linter.install_hint)
                ],
                True,
            )
        outcome = linter.run(executable, root, linter.select_files(project_files(root)))
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
    for linter in LINTERS:
        write_baseline(baseline_path(root, linter), recorded[linter.name])
    return Report(lines, False)


def main(arguments: List[str], environment: Mapping[str, str], repository_root: str) -> int:
    command = arguments[0] if arguments else ""
    if command not in (CHECK_COMMAND, UPDATE_COMMAND) or len(arguments) > 2:
        print("usage: lint_baseline.py check|update [ROOT]", file=sys.stderr)
        return USAGE_EXIT_CODE
    root = arguments[1] if len(arguments) == 2 else repository_root
    try:
        report = (
            run_check(root, environment)
            if command == CHECK_COMMAND
            else run_update(root, environment)
        )
    except ValueError as error:
        print("lint: %s" % error)
        return FINDINGS_EXIT_CODE
    for line in report.lines:
        print(line)
    return FINDINGS_EXIT_CODE if report.failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.environ, REPO_ROOT))

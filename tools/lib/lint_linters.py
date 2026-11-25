"""ShellCheck and Ruff: the files each lints, its findings, and a note on a version it differs at."""

from __future__ import annotations

import fnmatch
import functools
import json
import os
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from typing import Any, ClassVar, List, Mapping, Optional, Protocol, Sequence, Tuple

from lint_findings import (
    Failure,
    Finding,
    FindingMessage,
    LineNumber,
    LintResult,
    Pair,
    ProjectPath,
    ProjectRoot,
    RuleCode,
    ToolName,
)
from lint_project import (
    AcceptedExits,
    CommandLine,
    Executable,
    Project,
    checked_output,
    printed_output,
)

_GIT_HOOK_PATTERN = "plugins/*/hooks/git/*"
_GENERATED_RESULTS_FOLDER = "/evals/results/"
_SHELL_EXTENSION = ".sh"
_PYTHON_EXTENSION = ".py"
_SHELLCHECK_SEVERITY = "warning"
_SHELLCHECK_SOURCE_HANDLING = "--external-sources"
_SHELLCHECK_FORMAT = "json1"
_SHELLCHECK_RULE_CODE_FORMAT = "SC%d"
_RUFF_CONFIGURATION = "ruff.toml"
_RUFF_PIN_FILE = "tools/requirements-lint.txt"
_RUFF_PIN_PREFIX = "ruff=="
_RUFF_VERSION_PREFIX = "ruff "
_RUFF_SYNTAX_ERROR_CODE = "syntax-error"
_UNKNOWN_VERSION = "(unknown version)"


@dataclass(frozen=True)
class ChunkCount:
    value: int


@dataclass(frozen=True)
class InstallHint:
    text: str


@dataclass(frozen=True)
class VersionNote:
    text: str


class Linter(Protocol):
    name: ClassVar[ToolName]
    install_hint: ClassVar[InstallHint]

    def findings(self, executable: Executable, project: Project) -> LintResult: ...

    def version_notes(self, executable: Executable, root: ProjectRoot) -> Tuple[VersionNote, ...]: ...


def _is_git_hook(path: ProjectPath) -> bool:
    return fnmatch.fnmatchcase(path.value, _GIT_HOOK_PATTERN)


def _shell_files(files: Tuple[ProjectPath, ...]) -> Tuple[ProjectPath, ...]:
    return tuple(path for path in files if path.value.endswith(_SHELL_EXTENSION) or _is_git_hook(path))


def _python_files(files: Tuple[ProjectPath, ...]) -> Tuple[ProjectPath, ...]:
    return tuple(
        path
        for path in files
        if path.value.endswith(_PYTHON_EXTENSION)
        and _GENERATED_RESULTS_FOLDER not in "/" + path.value
    )


def _shellcheck_finding(comment: Mapping[str, Any]) -> Finding:
    return Finding(
        Pair(
            ProjectPath(comment["file"]),
            RuleCode(_SHELLCHECK_RULE_CODE_FORMAT % comment["code"]),
        ),
        LineNumber(comment["line"]),
        FindingMessage(comment["message"]),
    )


def _parsed_shellcheck_output(output: str) -> LintResult:
    try:
        return tuple(_shellcheck_finding(comment) for comment in json.loads(output)["comments"])
    except (ValueError, KeyError, TypeError):
        return Failure("shellcheck printed output that is not its json1 format")


def _shellcheck_chunk(
    executable: Executable, root: ProjectRoot, files: Tuple[ProjectPath, ...]
) -> LintResult:
    command = CommandLine(
        _ShellCheck.name,
        (
            executable.path,
            "--severity=" + _SHELLCHECK_SEVERITY,
            _SHELLCHECK_SOURCE_HANDLING,
            "--format=" + _SHELLCHECK_FORMAT,
            "--",
            *(path.value for path in files),
        ),
    )
    output = checked_output(command, root, AcceptedExits.SUCCESS_OR_FINDINGS)
    if isinstance(output, Failure):
        return output
    return _parsed_shellcheck_output(output.text)


def _file_chunks(
    files: Tuple[ProjectPath, ...], chunk_count: ChunkCount
) -> Tuple[Tuple[ProjectPath, ...], ...]:
    ordered = tuple(sorted(files))
    used_chunks = min(chunk_count.value, len(ordered))
    return tuple(ordered[start::used_chunks] for start in range(used_chunks))


def _merged_findings(results: Sequence[LintResult]) -> LintResult:
    findings: List[Finding] = []
    for result in results:
        if isinstance(result, Failure):
            return result
        findings.extend(result)
    return tuple(findings)


@dataclass(frozen=True)
class _ShellCheck:
    name: ClassVar[ToolName] = ToolName("shellcheck")
    install_hint: ClassVar[InstallHint] = InstallHint(
        "brew install shellcheck, or apt-get install shellcheck"
    )
    chunks: ChunkCount

    def findings(self, executable: Executable, project: Project) -> LintResult:
        chunks = _file_chunks(_shell_files(project.files), self.chunks)
        if not chunks:
            return ()
        run_chunk = functools.partial(_shellcheck_chunk, executable, project.root)
        with ThreadPoolExecutor(max_workers=len(chunks)) as pool:
            return _merged_findings(tuple(pool.map(run_chunk, chunks)))

    def version_notes(self, executable: Executable, root: ProjectRoot) -> Tuple[VersionNote, ...]:
        return ()


def _pinned_ruff_version(root: ProjectRoot) -> Optional[str]:
    try:
        with open(os.path.join(root.resolved_path, _RUFF_PIN_FILE), encoding="utf-8") as pin_file:
            lines = pin_file.read().splitlines()
    except OSError:
        return None
    pins = [
        line[len(_RUFF_PIN_PREFIX) :].strip() for line in lines if line.startswith(_RUFF_PIN_PREFIX)
    ]
    return pins[0] if pins else None


def _installed_ruff_version(executable: Executable, root: ProjectRoot) -> str:
    output = printed_output(CommandLine(_Ruff.name, (executable.path, "--version")), root)
    if isinstance(output, Failure):
        return _UNKNOWN_VERSION
    return output.text.strip().removeprefix(_RUFF_VERSION_PREFIX) or _UNKNOWN_VERSION


def _project_relative_path(reported: str, root: ProjectRoot) -> ProjectPath:
    relative = os.path.relpath(os.path.realpath(reported), root.resolved_path)
    return ProjectPath(relative.replace(os.sep, "/"))


def _ruff_finding(report: Mapping[str, Any], root: ProjectRoot) -> Finding:
    return Finding(
        Pair(
            _project_relative_path(report["filename"], root),
            RuleCode(report["code"] or _RUFF_SYNTAX_ERROR_CODE),
        ),
        LineNumber(report["location"]["row"]),
        FindingMessage(report["message"]),
    )


def _parsed_ruff_output(output: str, root: ProjectRoot) -> LintResult:
    try:
        return tuple(_ruff_finding(report, root) for report in json.loads(output))
    except (ValueError, KeyError, TypeError):
        return Failure("ruff printed output that is not its json format")


def _ruff_command(executable: Executable, root: ProjectRoot, files: Tuple[ProjectPath, ...]) -> CommandLine:
    return CommandLine(
        _Ruff.name,
        (
            executable.path,
            "check",
            "--no-cache",
            "--config",
            os.path.join(root.resolved_path, _RUFF_CONFIGURATION),
            "--output-format",
            "json",
            "--",
            *(path.value for path in files),
        ),
    )


@dataclass(frozen=True)
class _Ruff:
    name: ClassVar[ToolName] = ToolName("ruff")
    install_hint: ClassVar[InstallHint] = InstallHint("pip install -r " + _RUFF_PIN_FILE)

    def findings(self, executable: Executable, project: Project) -> LintResult:
        files = _python_files(project.files)
        if not files:
            return ()
        command = _ruff_command(executable, project.root, files)
        output = checked_output(command, project.root, AcceptedExits.SUCCESS_OR_FINDINGS)
        if isinstance(output, Failure):
            return output
        return _parsed_ruff_output(output.text, project.root)

    def version_notes(self, executable: Executable, root: ProjectRoot) -> Tuple[VersionNote, ...]:
        pinned = _pinned_ruff_version(root)
        if pinned is None:
            return ()
        installed = _installed_ruff_version(executable, root)
        if installed == pinned:
            return ()
        return (
            VersionNote(
                "ruff %s is installed but %s pins %s, so its findings may differ from the baseline"
                % (installed, _RUFF_PIN_FILE, pinned)
            ),
        )


def configured_linters(shellcheck_chunks: ChunkCount) -> Tuple[Linter, ...]:
    return (_ShellCheck(shellcheck_chunks), _Ruff())

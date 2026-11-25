"""The files git lists in a project, and the commands run in its root."""

from __future__ import annotations

import enum
import os
import subprocess
from dataclasses import dataclass
from typing import Tuple, Union

from lint_findings import Failure, ProjectPath, ProjectRoot, ToolName

_COMMAND_TIMEOUT_SECONDS = 300
_SUCCESS_EXIT_CODE = 0
_FINDINGS_EXIT_CODE = 1
_GIT_PATH_SEPARATOR = "\0"


@dataclass(frozen=True)
class Executable:
    path: str


@dataclass(frozen=True)
class CommandLine:
    tool: ToolName
    words: Tuple[str, ...]


@dataclass(frozen=True)
class CommandOutput:
    text: str


@dataclass(frozen=True)
class _ExitCode:
    value: int


@dataclass(frozen=True)
class _ErrorOutput:
    text: str


class AcceptedExits(enum.Enum):
    SUCCESS = (_ExitCode(_SUCCESS_EXIT_CODE),)
    SUCCESS_OR_FINDINGS = (_ExitCode(_SUCCESS_EXIT_CODE), _ExitCode(_FINDINGS_EXIT_CODE))


@dataclass(frozen=True)
class _CompletedCommand:
    exit_code: _ExitCode
    output: CommandOutput
    error_output: _ErrorOutput


@dataclass(frozen=True)
class Project:
    root: ProjectRoot
    files: Tuple[ProjectPath, ...]


_GIT_LIST_FILES = CommandLine(
    ToolName("git ls-files"),
    ("git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"),
)


def _completed(command: CommandLine, root: ProjectRoot) -> Union[_CompletedCommand, Failure]:
    program = command.words[0]
    try:
        completed = subprocess.run(  # noqa: S603
            list(command.words),
            cwd=root.resolved_path,
            capture_output=True,
            text=True,
            timeout=_COMMAND_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return Failure("%s did not finish in %d seconds" % (program, _COMMAND_TIMEOUT_SECONDS))
    except OSError as error:
        return Failure("%s did not start: %s" % (program, error))
    return _CompletedCommand(
        _ExitCode(completed.returncode),
        CommandOutput(completed.stdout),
        _ErrorOutput(completed.stderr.strip()),
    )


def printed_output(command: CommandLine, root: ProjectRoot) -> Union[CommandOutput, Failure]:
    result = _completed(command, root)
    return result if isinstance(result, Failure) else result.output


def checked_output(
    command: CommandLine, root: ProjectRoot, accepted: AcceptedExits
) -> Union[CommandOutput, Failure]:
    result = _completed(command, root)
    if isinstance(result, Failure):
        return result
    if result.error_output.text:
        return Failure(result.error_output.text)
    if result.exit_code not in accepted.value:
        return Failure(
            "%s exited %d: %s" % (command.tool.value, result.exit_code.value, result.output.text)
        )
    return result.output


def _is_regular_file(root: ProjectRoot, path: str) -> bool:
    full_path = os.path.join(root.resolved_path, path)
    return os.path.isfile(full_path) and not os.path.islink(full_path)


def project_files(root: ProjectRoot) -> Union[Project, Failure]:
    output = checked_output(_GIT_LIST_FILES, root, AcceptedExits.SUCCESS)
    if isinstance(output, Failure):
        return output
    listed = sorted(path for path in output.text.split(_GIT_PATH_SEPARATOR) if path)
    return Project(root, tuple(ProjectPath(path) for path in listed if _is_regular_file(root, path)))

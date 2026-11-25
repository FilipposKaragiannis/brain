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
git, shellcheck and ruff. Its modules sit beside it as lint_*.py.
"""

from __future__ import annotations

import argparse
import enum
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import List, Mapping, Optional

sys.dont_write_bytecode = True
sys.path.append(str(Path(__file__).resolve().parent))
from lint_findings import ProjectRoot  # noqa: E402
from lint_linters import ChunkCount, configured_linters  # noqa: E402
from lint_reports import Verdict, run_check, run_update  # noqa: E402

_REPOSITORY_ROOT = str(Path(__file__).resolve().parents[2])
_ROOT_MARKER = "ruff.toml"
_SHELLCHECK_MINIMUM_CHUNKS = 1
_SHELLCHECK_MAXIMUM_CHUNKS = 8
_SHELLCHECK_CHUNK_CHOICES = range(_SHELLCHECK_MINIMUM_CHUNKS, _SHELLCHECK_MAXIMUM_CHUNKS + 1)
_SUCCESS_EXIT_CODE = 0
_FINDINGS_EXIT_CODE = 1
_USAGE_EXIT_CODE = 2


class _Command(enum.Enum):
    CHECK = "check"
    UPDATE = "update"


@dataclass(frozen=True)
class _Invocation:
    command: _Command
    root: ProjectRoot
    shellcheck_chunks: ChunkCount


def _root_problem(root: ProjectRoot) -> Optional[str]:
    if os.path.isfile(os.path.join(root.resolved_path, _ROOT_MARKER)):
        return None
    return "%s is not a repository root: it holds no %s" % (root.resolved_path, _ROOT_MARKER)


def _parsed_invocation(
    arguments: List[str], repository_root: str, processor_count: int
) -> _Invocation:
    parser = argparse.ArgumentParser(prog="lint_baseline.py")
    parser.add_argument("command", choices=[command.value for command in _Command])
    parser.add_argument("root", nargs="?", default=repository_root)
    parser.add_argument(
        "--shellcheck-chunks", type=int, choices=_SHELLCHECK_CHUNK_CHOICES, metavar="N"
    )
    parsed = parser.parse_args(arguments)
    default_chunks = min(processor_count, _SHELLCHECK_MAXIMUM_CHUNKS)
    return _Invocation(
        _Command(parsed.command),
        ProjectRoot(os.path.realpath(parsed.root)),
        ChunkCount(parsed.shellcheck_chunks or default_chunks),
    )


def _exit_code(verdict: Verdict) -> int:
    return _FINDINGS_EXIT_CODE if verdict is Verdict.FAILED else _SUCCESS_EXIT_CODE


def _main(
    arguments: List[str], environment: Mapping[str, str], repository_root: str, processor_count: int
) -> int:
    invocation = _parsed_invocation(arguments, repository_root, processor_count)
    problem = _root_problem(invocation.root)
    if problem is not None:
        print("lint_baseline.py: " + problem, file=sys.stderr)
        return _USAGE_EXIT_CODE
    linters = configured_linters(invocation.shellcheck_chunks)
    command_runner = run_check if invocation.command is _Command.CHECK else run_update
    report = command_runner(invocation.root, environment, linters)
    for line in report.lines:
        print(line.text)
    return _exit_code(report.verdict)


if __name__ == "__main__":
    sys.exit(
        _main(
            sys.argv[1:], os.environ, _REPOSITORY_ROOT, os.cpu_count() or _SHELLCHECK_MINIMUM_CHUNKS
        )
    )

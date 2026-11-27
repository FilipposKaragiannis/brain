"""The gh runner scripts/_pr_publish.py and scripts/_pr_refresh.py call, injected so a test can
hand them another.

Each call names the folder gh runs in: CURRENT_FOLDER for every call but the later --attach
batches, which run in the reports folder because gh resolves a body's `./evidence/...`
references against it when no body file is given.
"""
import os
import subprocess
from dataclasses import dataclass
from typing import Callable, Sequence

from _pr_report_input import TEXT_ENCODING

GH_PROGRAM = "gh"
CURRENT_FOLDER = os.curdir
UNDECODABLE_BYTES = "replace"
# A video may be up to 100 MiB, and gh uploads every file before it returns.
GH_TIMEOUT_SECONDS = 1800
GH_SUCCEEDED_EXIT = 0
GH_NOT_RUN_EXIT = 127
GH_TIMED_OUT = "gh took longer than %d seconds"


@dataclass(frozen=True)
class GhResult:
    exit_code: int
    stdout: str
    stderr: str


GhRunner = Callable[[Sequence[str], str], GhResult]


def run_gh(arguments: Sequence[str], working_folder: str) -> GhResult:
    try:
        completed = subprocess.run(  # noqa: S603 - an argument list and no shell
            [GH_PROGRAM, *arguments], cwd=working_folder, capture_output=True, text=True, encoding=TEXT_ENCODING,
            errors=UNDECODABLE_BYTES, timeout=GH_TIMEOUT_SECONDS, check=False)
    except subprocess.TimeoutExpired:
        return GhResult(GH_NOT_RUN_EXIT, "", GH_TIMED_OUT % GH_TIMEOUT_SECONDS)
    except OSError as error:
        return GhResult(GH_NOT_RUN_EXIT, "", str(error))
    return GhResult(completed.returncode, completed.stdout, completed.stderr)

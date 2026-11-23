"""The changed file list verify reads, and whether it holds every change. See scripts/verify.sh.

  _change_list.py --log=<file> --summary=<file> --chosen-base=<file> --given=<base>
                  --claimed=<base> --recorded=<base> --task-branch=<branch> --fallback=<base>
      Chooses the comparison base (scripts/_verify_base.py) from the --base value (given), the
      claim's base when it is a valid base name (claimed), the base and the task branch the item's
      record holds (recorded, task branch) and the config base (fallback), each empty when there is
      none: an item whose record holds no base has only its claim to go by. Writes the comparison
      commit, or unavailable, and the base name, one line each, to the chosen base file, and why the
      commit is unavailable to the log. Lists the files changed since the comparison commit (none
      when it is unavailable), the files changed and not committed, and the untracked files, one
      git call each, with git's errors appended to the log. Prints each distinct name that is not
      under .flow/, in byte order, each followed by U+001F, and writes the summary of the failed
      `changed files` check, empty for a complete list, to the summary file. Each file is written
      through a temp file and a rename. A failed listing gives only the names its output ended with
      a NUL. Exits 0 for a complete list; 4 when verify cannot trust the comparison, the base
      cannot be resolved or a listing failed; 3, printing no name, when a name holds U+001F itself,
      which cannot be told from the separator; 2 on bad usage.
"""
from __future__ import annotations

import argparse
import enum
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import BinaryIO

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _verify_base import (  # noqa: E402
    GIT,
    GIT_TIMEOUT_SECONDS,
    HEAD,
    UNAVAILABLE_COMMIT,
    BaseSources,
    ChosenBase,
    chosen_base,
)

END_OF_REVISIONS = "--"
NAME_DIFF_ARGUMENTS = ("diff", "--no-renames", "--name-only", "-z")
UNTRACKED_ARGUMENTS = ("ls-files", "--others", "--exclude-standard", "-z")
FLOW_FOLDER = b".flow/"
NAME_TERMINATOR = b"\0"
NAME_SEPARATOR = b"\x1f"
CAUSE_SEPARATOR = "; "
SENTENCE_SEPARATOR = " "
UNREADABLE_NAME_CAUSE = "a changed file name holds the character U+001F, which verify cannot hand to a command"
UNTRUSTED_COMPARISON = "verify cannot trust the comparison, so it cannot pass: %s."
SHORT_LIST = "verify cannot list every changed file, so it cannot pass: %s."
EVERY_CHECK_RUNS = "Every check with paths runs."
UNAVAILABLE_BASE_LOG_LINE = "%s: every check with paths runs, and {verify_base} is unavailable\n"
OPTIONS = ("--log", "--summary", "--chosen-base", "--given", "--claimed", "--recorded", "--task-branch", "--fallback")


class ChangeList(enum.Enum):
    COMPLETE = 0
    UNREADABLE_NAMES = 3
    INCOMPLETE = 4


@dataclass(frozen=True)
class Listing:
    operation: str
    arguments: tuple[str, ...]


@dataclass(frozen=True)
class Listed:
    names: bytes
    causes: tuple[str, ...]


@dataclass(frozen=True)
class ChangedFiles:
    state: ChangeList
    names: tuple[bytes, ...]
    refusals: tuple[str, ...]
    causes: tuple[str, ...]


@dataclass(frozen=True)
class Options:
    log: str
    summary: str
    chosen_base: str
    sources: BaseSources


WORKING_TREE_LISTINGS = (
    Listing("the diff of uncommitted changes", NAME_DIFF_ARGUMENTS + (HEAD, END_OF_REVISIONS)),
    Listing("the listing of untracked files", UNTRACKED_ARGUMENTS),
)


def whole_names(output: bytes) -> bytes:
    return output[: output.rfind(NAME_TERMINATOR) + 1]


def listed_by(listing: Listing, log: BinaryIO) -> Listed:
    try:
        completed = subprocess.run(  # noqa: S603 - fixed git arguments and no shell
            (GIT,) + listing.arguments,
            stdout=subprocess.PIPE,
            stderr=log,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return Listed(b"", ("%s failed (%s)" % (listing.operation, error),))
    if completed.returncode != 0:
        cause = "%s failed (git exit %d, its error is in the log)" % (listing.operation, completed.returncode)
        return Listed(whole_names(completed.stdout), (cause,))
    return Listed(completed.stdout, ())


def committed_listed(base: ChosenBase, log: BinaryIO) -> Listed:
    comparison = base.comparison
    if comparison.commit == UNAVAILABLE_COMMIT:
        return Listed(b"", base.unresolved())
    operation = "the diff from the base %s" % comparison.name
    return listed_by(Listing(operation, NAME_DIFF_ARGUMENTS + (comparison.commit, HEAD, END_OF_REVISIONS)), log)


def all_listed(base: ChosenBase, log: BinaryIO) -> Listed:
    listed = (committed_listed(base, log),) + tuple(listed_by(listing, log) for listing in WORKING_TREE_LISTINGS)
    return Listed(b"".join(each.names for each in listed), tuple(cause for each in listed for cause in each.causes))


def distinct_names(raw: bytes) -> tuple[bytes, ...]:
    return tuple(sorted({name for name in raw.split(NAME_TERMINATOR) if name and not name.startswith(FLOW_FOLDER)}))


def state_of(causes: tuple[str, ...], state_when_listed: ChangeList) -> ChangeList:
    return ChangeList.INCOMPLETE if causes else state_when_listed


def changed_files(listed: Listed, refusals: tuple[str, ...]) -> ChangedFiles:
    names = distinct_names(listed.names)
    if any(NAME_SEPARATOR in name for name in names):
        causes = listed.causes + (UNREADABLE_NAME_CAUSE,)
        return ChangedFiles(state_of(refusals + listed.causes, ChangeList.UNREADABLE_NAMES), (), refusals, causes)
    return ChangedFiles(state_of(refusals + listed.causes, ChangeList.COMPLETE), names, refusals, listed.causes)


def sentence(template: str, causes: tuple[str, ...]) -> tuple[str, ...]:
    return (template % CAUSE_SEPARATOR.join(causes),) if causes else ()


def summary_of(changed: ChangedFiles) -> str:
    if changed.state is not ChangeList.INCOMPLETE:
        return CAUSE_SEPARATOR.join(changed.causes)
    said = sentence(UNTRUSTED_COMPARISON, changed.refusals) + sentence(SHORT_LIST, changed.causes)
    return SENTENCE_SEPARATOR.join(said + (EVERY_CHECK_RUNS,))


def unavailable_base_line(base: ChosenBase) -> bytes:
    if base.comparison.commit != UNAVAILABLE_COMMIT:
        return b""
    return (UNAVAILABLE_BASE_LOG_LINE % CAUSE_SEPARATOR.join(base.refusals + base.unresolved())).encode("utf-8")


def replaced_atomically(path: str, content: str) -> None:
    folder, name = os.path.split(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".%s." % name, dir=folder or os.curdir)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as temporary_file:
            temporary_file.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def parsed_options(arguments: list[str]) -> Options:
    parser = argparse.ArgumentParser(prog="_change_list.py", allow_abbrev=False)
    for option in OPTIONS:
        parser.add_argument(option, required=True)
    parsed = parser.parse_args(arguments)
    sources = BaseSources(parsed.given, parsed.claimed, parsed.recorded, parsed.task_branch, parsed.fallback)
    return Options(parsed.log, parsed.summary, parsed.chosen_base, sources)


def main(arguments: list[str]) -> int:
    options = parsed_options(arguments)
    base = chosen_base(options.sources)
    with open(options.log, "ab") as log_file:
        log_file.write(unavailable_base_line(base))
        log_file.flush()
        changed = changed_files(all_listed(base, log_file), base.refusals)
    replaced_atomically(options.chosen_base, "%s\n%s\n" % (base.comparison.commit, base.comparison.name))
    replaced_atomically(options.summary, summary_of(changed))
    sys.stdout.buffer.write(b"".join(name + NAME_SEPARATOR for name in changed.names))
    return changed.state.value


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

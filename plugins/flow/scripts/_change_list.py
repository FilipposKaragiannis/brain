"""The changed file list verify reads, and whether it holds every change. See scripts/verify.sh.

  _change_list.py <log> <causes file> <base name> <base commit | unavailable>
      Lists the files changed since the base commit (none when it is unavailable), the files
      changed and not committed, and the untracked files, one git call each, with git's errors
      appended to the log. Prints each distinct name that is not under .flow/, in byte order, each
      followed by U+001F, and writes the cause of each failed listing, joined by "; ", to the
      causes file. Exits 0 for a complete list, 4 when a listing failed or the base is
      unavailable, and 3, printing no name, when a name holds U+001F itself, which cannot be told
      from the separator.
"""
from __future__ import annotations

import enum
import subprocess
import sys
from dataclasses import dataclass
from typing import BinaryIO, Union

GIT = "git"
GIT_TIMEOUT_SECONDS = 300
HEAD = "HEAD"
NAME_DIFF_ARGUMENTS = ("diff", "--no-renames", "--name-only", "-z")
UNTRACKED_ARGUMENTS = ("ls-files", "--others", "--exclude-standard", "-z")
UNAVAILABLE_COMMIT = "unavailable"
FLOW_FOLDER = b".flow/"
NAME_TERMINATOR = b"\0"
NAME_SEPARATOR = b"\x1f"
CAUSE_SEPARATOR = "; "
UNREADABLE_NAME_CAUSE = "a changed file name holds the character U+001F, which verify cannot hand to a command"
ARGUMENT_COUNT = 4
USAGE_EXIT = 2
USAGE = "usage: _change_list.py <log> <causes file> <base name> <base commit | unavailable>"


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
    causes: tuple[str, ...]


WORKING_TREE_LISTINGS = (
    Listing("the diff of uncommitted changes", NAME_DIFF_ARGUMENTS + (HEAD,)),
    Listing("the listing of untracked files", UNTRACKED_ARGUMENTS),
)


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
        return Listed(completed.stdout, (cause,))
    return Listed(completed.stdout, ())


@dataclass(frozen=True)
class ResolvedBase:
    name: str
    commit: str

    def listed(self, log: BinaryIO) -> Listed:
        operation = "the diff from the base %s" % self.name
        return listed_by(Listing(operation, NAME_DIFF_ARGUMENTS + (self.commit, HEAD)), log)


@dataclass(frozen=True)
class UnresolvedBase:
    name: str

    def listed(self, log: BinaryIO) -> Listed:
        return Listed(b"", ("the comparison base %s cannot be resolved" % self.name,))


def comparison_base(name: str, commit: str) -> Union[ResolvedBase, UnresolvedBase]:
    if commit == UNAVAILABLE_COMMIT:
        return UnresolvedBase(name)
    return ResolvedBase(name, commit)


def all_listed(base: Union[ResolvedBase, UnresolvedBase], log: BinaryIO) -> Listed:
    listed = (base.listed(log),) + tuple(listed_by(listing, log) for listing in WORKING_TREE_LISTINGS)
    return Listed(b"".join(each.names for each in listed), tuple(cause for each in listed for cause in each.causes))


def distinct_names(raw: bytes) -> tuple[bytes, ...]:
    return tuple(sorted({name for name in raw.split(NAME_TERMINATOR) if name and not name.startswith(FLOW_FOLDER)}))


def state_of(causes: tuple[str, ...], state_when_listed: ChangeList) -> ChangeList:
    return ChangeList.INCOMPLETE if causes else state_when_listed


def changed_files(listed: Listed) -> ChangedFiles:
    names = distinct_names(listed.names)
    if any(NAME_SEPARATOR in name for name in names):
        causes = listed.causes + (UNREADABLE_NAME_CAUSE,)
        return ChangedFiles(state_of(listed.causes, ChangeList.UNREADABLE_NAMES), (), causes)
    return ChangedFiles(state_of(listed.causes, ChangeList.COMPLETE), names, listed.causes)


def main(arguments: list[str]) -> int:
    if len(arguments) != ARGUMENT_COUNT:
        print(USAGE, file=sys.stderr)
        return USAGE_EXIT
    log, causes_file, base_name, base_commit = arguments
    with open(log, "ab") as log_file:
        changed = changed_files(all_listed(comparison_base(base_name, base_commit), log_file))
    with open(causes_file, "w", encoding="utf-8") as causes:
        causes.write(CAUSE_SEPARATOR.join(changed.causes))
    sys.stdout.buffer.write(b"".join(name + NAME_SEPARATOR for name in changed.names))
    return changed.state.value


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

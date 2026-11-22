"""The changed file list verify reads, and whether it holds every change. See scripts/verify.sh.

  _change_list.py <log> <causes file> <base name> <base commit | unavailable> <claimed base>
                  <recorded base> <fallback base> <recorded task branch>
      Lists the files changed since the base commit (none when it is unavailable), the files
      changed and not committed, and the untracked files, one git call each, with git's errors
      appended to the log. Prints each distinct name that is not under .flow/, in byte order, each
      followed by U+001F, and writes the cause of each failed listing, joined by "; ", to the
      causes file through a temp file and a rename. A failed listing gives only the names its
      output ended with a NUL. Exits 0 for a complete list, 4 when a listing failed or the base is
      unavailable or untrusted, and 3, printing no name, when a name holds U+001F itself, which
      cannot be told from the separator.
      The claimed base is the claim's base when verify read the claim, else empty; the recorded
      base and task branch are the item state's, else empty; the fallback base is the config base.
      Branches are read by their full ref, the remote's when origin has one, so no tag of the
      same name stands in. The base is untrusted when it is the item's own branch: it names the
      current branch or the recorded task branch while it is not the base outside the worktree
      (the recorded base, else the fallback), or its commit is HEAD while HEAD holds commits the
      item's base (the recorded base, else the claimed, else the fallback) does not. When a
      claimed and a recorded base differ, the base name is empty and verify lists no committed
      change, names both and judges the claimed base by its name alone: the claim sits in the
      worktree whose work is verified, the record does not, and verify cannot tell which is the
      item's.
"""
from __future__ import annotations

import enum
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import BinaryIO, Union

GIT = "git"
GIT_TIMEOUT_SECONDS = 300
HEAD = "HEAD"
END_OF_REVISIONS = "--"
NAME_DIFF_ARGUMENTS = ("diff", "--no-renames", "--name-only", "-z")
UNTRACKED_ARGUMENTS = ("ls-files", "--others", "--exclude-standard", "-z")
UNAVAILABLE_COMMIT = "unavailable"
CURRENT_BRANCH_ARGUMENTS = ("symbolic-ref", "--short", "-q", HEAD)
HEAD_COMMIT_ARGUMENTS = ("rev-parse", "--verify", "-q", HEAD + "^{commit}")
ORIGIN_BRANCH_PREFIX = "refs/remotes/origin/"
LOCAL_BRANCH_PREFIX = "refs/heads/"
GIT_SUCCESS = 0
GIT_DID_NOT_RUN = -1
FLOW_FOLDER = b".flow/"
NAME_TERMINATOR = b"\0"
NAME_SEPARATOR = b"\x1f"
CAUSE_SEPARATOR = "; "
UNREADABLE_NAME_CAUSE = "a changed file name holds the character U+001F, which verify cannot hand to a command"
ARGUMENT_COUNT = 8
USAGE_EXIT = 2
USAGE = (
    "usage: _change_list.py <log> <causes file> <base name> <base commit | unavailable>"
    " <claimed base> <recorded base> <fallback base> <recorded task branch>"
)


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


@dataclass(frozen=True)
class ResolvedBase:
    name: str
    commit: str

    def listed(self, log: BinaryIO) -> Listed:
        operation = "the diff from the base %s" % self.name
        return listed_by(Listing(operation, NAME_DIFF_ARGUMENTS + (self.commit, HEAD, END_OF_REVISIONS)), log)


@dataclass(frozen=True)
class UnresolvedBase:
    name: str

    def listed(self, log: BinaryIO) -> Listed:
        return Listed(b"", ("the comparison base %s cannot be resolved" % self.name,))


@dataclass(frozen=True)
class DisputedBase:
    causes: tuple[str, ...]

    def listed(self, log: BinaryIO) -> Listed:
        return Listed(b"", self.causes)


@dataclass(frozen=True)
class GitAnswer:
    exit_code: int
    output: str


def git_answer(arguments: tuple[str, ...], log: BinaryIO) -> GitAnswer:
    try:
        completed = subprocess.run(  # noqa: S603 - fixed git arguments and no shell
            (GIT,) + arguments,
            stdout=subprocess.PIPE,
            stderr=log,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return GitAnswer(GIT_DID_NOT_RUN, "")
    return GitAnswer(completed.returncode, completed.stdout.decode("utf-8", "replace").strip())


def branch_ref(name: str, log: BinaryIO) -> str:
    origin_ref = ORIGIN_BRANCH_PREFIX + name
    if git_answer(("show-ref", "--verify", "--quiet", origin_ref), log).exit_code == GIT_SUCCESS:
        return origin_ref
    return LOCAL_BRANCH_PREFIX + name


def holds_head(name: str, log: BinaryIO) -> bool:
    return git_answer(("merge-base", "--is-ancestor", HEAD, branch_ref(name, log)), log).exit_code == GIT_SUCCESS


@dataclass(frozen=True)
class BaseRecord:
    claimed: str
    recorded: str
    fallback: str
    task_branch: str

    def base_outside_the_worktree(self) -> str:
        return self.recorded or self.fallback

    def item_base(self) -> str:
        return self.recorded or self.claimed or self.fallback

    def disagreement(self) -> tuple[str, ...]:
        if self.claimed and self.recorded and self.claimed != self.recorded:
            return ("the claim names the base %s, the item's record names %s" % (self.claimed, self.recorded),)
        return ()


def own_branch_names(record: BaseRecord, log: BinaryIO) -> frozenset[str]:
    return frozenset(name for name in (git_answer(CURRENT_BRANCH_ARGUMENTS, log).output, record.task_branch) if name)


def is_own_branch(name: str, commit: str, record: BaseRecord, log: BinaryIO) -> bool:
    if name != record.base_outside_the_worktree() and name in own_branch_names(record, log):
        return True
    head_commit = git_answer(HEAD_COMMIT_ARGUMENTS, log).output
    return commit == head_commit and not holds_head(record.item_base(), log)


def own_branch_causes(name: str, commit: str, record: BaseRecord, log: BinaryIO) -> tuple[str, ...]:
    if is_own_branch(name, commit, record, log):
        return ("the comparison base %s is the item's own branch" % name,)
    return ()


def comparison_base(name: str, commit: str, record: BaseRecord) -> Union[ResolvedBase, UnresolvedBase, DisputedBase]:
    if record.disagreement():
        return DisputedBase(record.disagreement())
    if commit == UNAVAILABLE_COMMIT:
        return UnresolvedBase(name)
    return ResolvedBase(name, commit)


def all_listed(base: Union[ResolvedBase, UnresolvedBase, DisputedBase], log: BinaryIO) -> Listed:
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


def main(arguments: list[str]) -> int:
    if len(arguments) != ARGUMENT_COUNT:
        print(USAGE, file=sys.stderr)
        return USAGE_EXIT
    log, causes_file, base_name, base_commit, claimed_base, recorded_base, fallback_base, task_branch = arguments
    record = BaseRecord(claimed_base, recorded_base, fallback_base, task_branch)
    with open(log, "ab") as log_file:
        own_branch = own_branch_causes(base_name or record.claimed, base_commit, record, log_file)
        listed = all_listed(comparison_base(base_name, base_commit, record), log_file)
        changed = changed_files(Listed(listed.names, own_branch + listed.causes))
    replaced_atomically(causes_file, CAUSE_SEPARATOR.join(changed.causes))
    sys.stdout.buffer.write(b"".join(name + NAME_SEPARATOR for name in changed.names))
    return changed.state.value


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

"""The comparison base verify trusts, chosen once a run. scripts/_change_list.py imports it.

chosen_base(sources) names the base verify compares the item's work with: the --base value, else
the claim's base and the base the item's record holds, either alone when the other is empty, else
the config base. An item whose record holds no base has only its claim to go by. A claim base that
differs from the record's base is neither, and the run has no base: the claim sits in the
worktree whose work is verified, the record does not, and verify cannot tell which is the item's.
A base is read by its full branch ref, the remote's when origin has one, so no tag of the same
name stands in. Its comparison commit is where it meets HEAD, else its tip, else unavailable.

The comparison is refused, its commit unavailable and each cause named, when:
- verify cannot read HEAD's commit or the branch HEAD is on, which fails closed;
- the base is the item's own branch: it names HEAD's branch or the task branch the record holds
  and is not the base outside the worktree (the record's base, else the config base), or its
  comparison commit is HEAD while the item's base (the record's, else the claim's, else the config
  base) lacks a commit HEAD holds; a claim base the record disputes is judged by its name alone;
- the record holds a task branch that exists and HEAD is not at its commit;
- the claim and the record name different bases.
Every git call here only reads, with its errors dropped: a failure that matters is a cause.
"""
from __future__ import annotations

import subprocess
from dataclasses import dataclass
from typing import Union

GIT = "git"
GIT_TIMEOUT_SECONDS = 300
GIT_SUCCESS = 0
GIT_DID_NOT_RUN = -1
DETACHED_HEAD_EXIT = 1
NO_SUCH_REVISION_EXIT = 1
HEAD = "HEAD"
COMMIT_OF = "^{commit}"
UNAVAILABLE_COMMIT = "unavailable"
NO_BASE = ""
ORIGIN_BRANCH_PREFIX = "refs/remotes/origin/"
LOCAL_BRANCH_PREFIX = "refs/heads/"
HEAD_BRANCH_ARGUMENTS = ("symbolic-ref", "-q", HEAD)
READABLE_HEAD_BRANCH_EXITS = (GIT_SUCCESS, DETACHED_HEAD_EXIT)
UNREADABLE_HEAD = "verify cannot read HEAD"


@dataclass(frozen=True)
class GitAnswer:
    exit_code: int
    output: str


def git_answer(arguments: tuple[str, ...]) -> GitAnswer:
    try:
        completed = subprocess.run(  # noqa: S603 - fixed git arguments and no shell
            (GIT,) + arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return GitAnswer(GIT_DID_NOT_RUN, "")
    return GitAnswer(completed.returncode, completed.stdout.decode("utf-8", "replace").strip())


def commit_answer(revision: str) -> GitAnswer:
    return git_answer(("rev-parse", "--verify", "-q", revision + COMMIT_OF))


def commit_of(revision: str) -> str:
    answer = commit_answer(revision)
    return answer.output if answer.exit_code == GIT_SUCCESS else UNAVAILABLE_COMMIT


def branch_ref(name: str) -> str:
    origin_ref = ORIGIN_BRANCH_PREFIX + name
    if git_answer(("show-ref", "--verify", "--quiet", origin_ref)).exit_code == GIT_SUCCESS:
        return origin_ref
    return LOCAL_BRANCH_PREFIX + name


def comparison_commit(name: str) -> str:
    if not name:
        return UNAVAILABLE_COMMIT
    ref = branch_ref(name)
    meeting = git_answer(("merge-base", ref, HEAD))
    return meeting.output if meeting.exit_code == GIT_SUCCESS else commit_of(ref)


@dataclass(frozen=True)
class BaseSources:
    given: str
    claimed: str
    recorded: str
    task_branch: str
    fallback: str

    def disputed(self) -> bool:
        return not self.given and bool(self.claimed) and bool(self.recorded) and self.claimed != self.recorded

    def chosen_name(self) -> str:
        if self.given:
            return self.given
        if self.disputed():
            return NO_BASE
        return self.claimed or self.recorded or self.fallback

    def judged_name(self) -> str:
        return self.chosen_name() or self.claimed

    def base_outside_the_worktree(self) -> str:
        return self.recorded or self.fallback

    def item_base(self) -> str:
        return self.recorded or self.claimed or self.fallback

    def dispute(self) -> tuple[str, ...]:
        if self.disputed():
            return ("the claim names the base %s, the item's record names %s" % (self.claimed, self.recorded),)
        return ()


@dataclass(frozen=True)
class Comparison:
    name: str
    commit: str


def holds(name: str, commit: str) -> bool:
    return git_answer(("merge-base", "--is-ancestor", commit, branch_ref(name))).exit_code == GIT_SUCCESS


@dataclass(frozen=True)
class ReadHead:
    commit: str
    branch: str

    def is_own_branch(self, sources: BaseSources, comparison: Comparison) -> bool:
        own_names = {self.branch, sources.task_branch} - {""}
        name = sources.judged_name()
        if name != sources.base_outside_the_worktree() and name in own_names:
            return True
        return comparison.commit == self.commit and not holds(sources.item_base(), self.commit)

    def is_off_the_task_branch(self, sources: BaseSources) -> bool:
        if not sources.task_branch:
            return False
        task_commit = commit_answer(LOCAL_BRANCH_PREFIX + sources.task_branch)
        return task_commit.exit_code != NO_SUCH_REVISION_EXIT and task_commit.output != self.commit

    def refusals(self, sources: BaseSources, comparison: Comparison) -> tuple[str, ...]:
        judged = (
            ("the comparison base %s is the item's own branch" % sources.judged_name(), self.is_own_branch(sources, comparison)),
            ("HEAD is not the item's branch %s" % sources.task_branch, self.is_off_the_task_branch(sources)),
        )
        return tuple(cause for cause, refused in judged if refused)


@dataclass(frozen=True)
class UnreadableHead:
    def refusals(self, sources: BaseSources, comparison: Comparison) -> tuple[str, ...]:
        return (UNREADABLE_HEAD,)


def branch_name(symbolic_ref: str) -> str:
    return symbolic_ref[len(LOCAL_BRANCH_PREFIX):] if symbolic_ref.startswith(LOCAL_BRANCH_PREFIX) else ""


def read_head() -> Union[ReadHead, UnreadableHead]:
    commit = commit_of(HEAD)
    branch = git_answer(HEAD_BRANCH_ARGUMENTS)
    if commit == UNAVAILABLE_COMMIT or branch.exit_code not in READABLE_HEAD_BRANCH_EXITS:
        return UnreadableHead()
    return ReadHead(commit, branch_name(branch.output))


@dataclass(frozen=True)
class ChosenBase:
    comparison: Comparison
    refusals: tuple[str, ...]

    def unresolved(self) -> tuple[str, ...]:
        if self.refusals or self.comparison.commit != UNAVAILABLE_COMMIT:
            return ()
        return ("the comparison base %s cannot be resolved" % self.comparison.name,)


def chosen_base(sources: BaseSources) -> ChosenBase:
    name = sources.chosen_name()
    measured = Comparison(name, comparison_commit(name))
    refusals = sources.dispute() + read_head().refusals(sources, measured)
    if refusals:
        return ChosenBase(Comparison(name, UNAVAILABLE_COMMIT), refusals)
    return ChosenBase(measured, ())

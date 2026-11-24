"""The ready: policy of the flow config (lib/ready.sh checks and exports it) laid on one joined item:
held elsewhere, tracker category and assignees, for the ready filter and next.sh.

Pure but for the adapters' me.sh, which MeNames reads once per adapter. Held means the record has a
claim, or, with no record, the tracker's state has a step (lazy seed): the flow started it here. A
held item is judged by neither category nor assignees, because the flow set them. A claim naming
another machine (a shared state.dir) is never ready. A me.sh that fails stands for no one: an item
only it would match stays back, and an unassigned one stays ready.

Run as a script (next.sh) with the plugin folder and the item's adapter, it reads one joined item
on stdin and prints why the policy keeps it back, the word and its detail on the next line (the
machine, the category, or the assignees comma-separated), or nothing when it passes.
"""
from __future__ import annotations

import functools
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from types import MappingProxyType
from typing import Callable, Mapping

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _state_join as join  # noqa: E402
import _state_schema as schema  # noqa: E402

ELSEWHERE, STATUS, ASSIGNED = "elsewhere", "status", "assigned"
WORDS = (ELSEWHERE, STATUS, ASSIGNED)
ASSIGNEE_NONE, ASSIGNEE_ME, ASSIGNEE_ANY = "none", "me", "any"
ASSIGNEE_WORDS = frozenset({ASSIGNEE_NONE, ASSIGNEE_ME, ASSIGNEE_ANY})
CATEGORY_UNKNOWN = "unknown"
VALUE_SEPARATOR = ","
DETAIL_SEPARATOR = ", "
ASSIGNEES_DETAIL = "assignees"
MACHINE_VARIABLE = "FLOW_MACHINE"
CATEGORIES_VARIABLE = "READY_CATEGORIES"
ASSIGNEE_VARIABLE = "READY_ASSIGNEE"
# How long one adapter's me.sh may take (a gh or Jira call) before me stands for no one.
ME_TIMEOUT_SECONDS = 60


@dataclass(frozen=True)
class ReadyPolicy:
    machine: str
    categories: frozenset[str]
    assignees: frozenset[str]


@dataclass(frozen=True)
class NotReady:
    why: str
    detail: Mapping[str, object]


READY = NotReady("", MappingProxyType({}))


def names(text: str) -> frozenset[str]:
    return frozenset(name.strip().lower() for name in text.split(VALUE_SEPARATOR) if name.strip())


def policy_from(environment: Mapping[str, str]) -> ReadyPolicy:
    return ReadyPolicy(environment[MACHINE_VARIABLE], names(environment[CATEGORIES_VARIABLE]),
                       names(environment[ASSIGNEE_VARIABLE]))


def held(item: Mapping) -> bool:
    if item.get(join.CLAIM_FIELD) is not None:
        return True
    started = bool((item.get(join.STATE_FIELD) or {}).get("step"))
    return item.get(join.STATE_FROM_FIELD) == join.FROM_TRACKER and started


def category_of(item: Mapping) -> str:
    return item.get("category") or CATEGORY_UNKNOWN


def assignees_of(item: Mapping) -> frozenset[str]:
    return frozenset(str(assignee).lower() for assignee in item.get("assignees") or [])


def assignees_allowed(item: Mapping, policy: ReadyPolicy, me_names: Callable[[], frozenset[str]]) -> bool:
    assignees = assignees_of(item)
    if ASSIGNEE_ANY in policy.assignees:
        return True
    if not assignees:
        return ASSIGNEE_NONE in policy.assignees
    unnamed = assignees - (policy.assignees - ASSIGNEE_WORDS)
    return not unnamed or (ASSIGNEE_ME in policy.assignees and unnamed <= me_names())


def not_ready(item: Mapping, policy: ReadyPolicy, me_names: Callable[[], frozenset[str]]) -> NotReady:
    """Why the policy keeps the item back, elsewhere before status before assigned, or READY. me_names
    gives what me stands for on the item's adapter; it is asked only for an assignee the policy
    does not name."""
    if schema.claimed_elsewhere(item, policy.machine):
        return NotReady(ELSEWHERE, MappingProxyType({"machine": item[join.CLAIM_FIELD]["machine"]}))
    if held(item):
        return READY
    if category_of(item) not in policy.categories:
        return NotReady(STATUS, MappingProxyType({"category": category_of(item)}))
    if not assignees_allowed(item, policy, me_names):
        return NotReady(ASSIGNED, MappingProxyType({ASSIGNEES_DETAIL: list(item.get("assignees") or [])}))
    return READY


class MeNames:
    """What me stands for on each adapter, lower case, read through its me.sh once. A failed read
    stands for no one and is said once through warn."""

    def __init__(self, plugin: str, warn: Callable[[str], None]) -> None:
        self._plugin = plugin
        self._warn = warn
        self._read: dict[str, frozenset[str]] = {}

    def read_names(self, adapter: str) -> frozenset[str]:
        if adapter not in self._read:
            self._read[adapter] = self._run_me(adapter)
        return self._read[adapter]

    def _run_me(self, adapter: str) -> frozenset[str]:
        command = os.path.join(self._plugin, "adapters", adapter, "me.sh")
        try:
            done = subprocess.run(  # noqa: S603 - the plugin's own me.sh and no shell
                [command], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=ME_TIMEOUT_SECONDS)
        except (OSError, subprocess.TimeoutExpired) as error:
            return self._failed(adapter, str(error))
        if done.returncode != 0:
            return self._failed(adapter, done.stderr.strip() or f"exit {done.returncode}")
        return frozenset(line.strip().lower() for line in done.stdout.splitlines() if line.strip())

    def _failed(self, adapter: str, because: str) -> frozenset[str]:
        self._warn(f"flow: ready.assignee names me, but the {adapter} adapter's me failed ({because}); "
                   "an item assigned to me is not ready this time")
        return frozenset()


def detail_text(verdict: NotReady) -> str:
    """The detail of a verdict in words: the assignees comma-separated, else its one value."""
    if verdict.why == ASSIGNED:
        return DETAIL_SEPARATOR.join(str(assignee) for assignee in verdict.detail[ASSIGNEES_DETAIL])
    return DETAIL_SEPARATOR.join(str(value) for value in verdict.detail.values())


def main(plugin: str, adapter: str) -> int:
    item = json.load(sys.stdin)
    me = MeNames(plugin, functools.partial(print, file=sys.stderr))
    verdict = not_ready(item, policy_from(os.environ), functools.partial(me.read_names, adapter))
    if verdict.why:
        print(verdict.why)
        print(detail_text(verdict))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))

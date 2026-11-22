"""The Flow suites the runner's lanes have running, for a stop to reach: a lane tracks each suite
for as long as it runs, and once a stop closes admission, a suite a lane starts afterwards has its
process group killed at once, so no suite starts unseen while the stop is under way."""
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from enum import Enum

from flow_clock import Duration
from flow_process_groups import LedGroup, kill_group

_NO_TIME = Duration(0)


class _Admission(Enum):
    OPEN = "open"
    CLOSED = "closed"


@dataclass(frozen=True)
class Admitted:
    suite: LedGroup
    time_limit: Duration


def _killed_at_once(suite: LedGroup) -> Admitted:
    kill_group(suite)
    return Admitted(suite, _NO_TIME)


class RunningSuites:
    def __init__(self) -> None:
        self._suites: "set[LedGroup]" = set()
        self._admission = _Admission.OPEN
        self._lock = threading.RLock()

    @contextmanager
    def track_or_kill_after_the_close(self, suite: LedGroup, time_limit: Duration) -> Iterator[Admitted]:
        with self._lock:
            self._suites.add(suite)
            admitted = Admitted(suite, time_limit) if self._admission is _Admission.OPEN else _killed_at_once(suite)
        try:
            yield admitted
        finally:
            with self._lock:
                self._suites.discard(suite)

    def close(self) -> None:
        with self._lock:
            self._admission = _Admission.CLOSED

    def still_running(self) -> "frozenset[LedGroup]":
        with self._lock:
            return frozenset(self._suites)

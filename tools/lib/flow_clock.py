"""The time a Flow suite run reads and waits on, always through a clock its caller gives it, such
as the system clock."""
import time
from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum
from typing import Protocol


@dataclass(frozen=True)
class Duration:
    seconds: float


@dataclass(frozen=True)
class Instant:
    seconds: float


class Clock(Protocol):
    def now(self) -> Instant: ...

    def sleep(self, duration: Duration) -> None: ...


class SystemClock:
    def now(self) -> Instant:
        return Instant(time.monotonic())

    def sleep(self, duration: Duration) -> None:
        time.sleep(duration.seconds)


class Ending(Enum):
    EXITED = "exited"
    TIMED_OUT = "timed out"


_POLL_INTERVAL = Duration(0.1)


def ending_by(ended: Callable[[], bool], deadline: Instant, clock: Clock) -> Ending:
    while not ended():
        if clock.now().seconds >= deadline.seconds:
            return Ending.TIMED_OUT
        clock.sleep(_POLL_INTERVAL)
    return Ending.EXITED


def ending_within(ended: Callable[[], bool], limit: Duration, clock: Clock) -> Ending:
    return ending_by(ended, Instant(clock.now().seconds + limit.seconds), clock)

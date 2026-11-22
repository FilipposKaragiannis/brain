"""Signal a Flow suite's process group, tell whether any member of it is still running, and stop
groups: TERM, one grace time shared by all that also bounds every look at the process listing, then
KILL for every group once the grace runs out, or KILL at once."""
import os
import signal
import subprocess
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

from flow_clock import Clock, Duration, Ending, Instant, ending_by


_PRESENCE_PROBE_SIGNAL = 0
_ZOMBIE_STATE = "Z"
_STATE_FIELD = 0
_PROCESS_GROUP_FIELD = 2
_LISTING_GROUP_COLUMN = 0
_LISTING_STATE_COLUMN = 1
_LISTING_COLUMNS = 2
_PROCESS_LISTING_LIMIT_SECONDS = 10
_NO_TIME_LEFT_SECONDS = 0


@dataclass(frozen=True)
class ProcessGroupId:
    number: int


@dataclass(frozen=True)
class LedGroup:
    leader: subprocess.Popen
    group: ProcessGroupId


@dataclass(frozen=True)
class ProcessTable:
    folder: Path


PROCESS_TABLE = ProcessTable(Path("/proc"))


@dataclass(frozen=True)
class _Deadline:
    at: Instant
    clock: Clock


class Membership(Enum):
    MEMBERS_REMAIN = "members remain"
    NO_MEMBER_REMAINS = "no member remains"
    UNKNOWN = "unknown"


def _signal_group(group: ProcessGroupId, sent: signal.Signals) -> bool:
    try:
        os.killpg(group.number, sent)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def _names_group(field: str, group: ProcessGroupId) -> bool:
    return field.isascii() and field.isdigit() and int(field) == group.number


def _membership_of(states: "list[str]") -> Membership:
    live = any(not state.startswith(_ZOMBIE_STATE) for state in states)
    return Membership.MEMBERS_REMAIN if live else Membership.NO_MEMBER_REMAINS


def _fields_after_name(status: Path) -> "list[str]":
    try:
        line = status.read_bytes().decode(errors="replace")
    except OSError:
        return []
    return line.rpartition(")")[2].split() if ")" in line else []


def _states_in_process_table(group: ProcessGroupId, statuses: "list[Path]") -> "list[str]":
    rows = (_fields_after_name(status) for status in statuses)
    return [fields[_STATE_FIELD] for fields in rows if len(fields) > _PROCESS_GROUP_FIELD and _names_group(fields[_PROCESS_GROUP_FIELD], group)]


def table_membership(group: ProcessGroupId, table: ProcessTable) -> Membership:
    try:
        with os.scandir(table.folder) as entries:
            statuses = [Path(entry.path, "stat") for entry in entries if entry.name.isascii() and entry.name.isdigit()]
    except OSError:
        return Membership.UNKNOWN
    return _membership_of(_states_in_process_table(group, statuses))


def _states_in_process_listing(group: ProcessGroupId, lines: "list[str]") -> "list[str]":
    rows = (line.split() for line in lines)
    return [row[_LISTING_STATE_COLUMN] for row in rows if len(row) == _LISTING_COLUMNS and _names_group(row[_LISTING_GROUP_COLUMN], group)]


def listing_membership(group: ProcessGroupId, time_left: Duration) -> Membership:
    if time_left.seconds <= _NO_TIME_LEFT_SECONDS:
        return Membership.UNKNOWN
    try:
        listing = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, timeout=min(time_left.seconds, _PROCESS_LISTING_LIMIT_SECONDS), check=False)
    except (OSError, subprocess.TimeoutExpired):
        return Membership.UNKNOWN
    if listing.returncode != 0:
        return Membership.UNKNOWN
    return _membership_of(_states_in_process_listing(group, listing.stdout.decode(errors="replace").splitlines()))


def _time_left(deadline: _Deadline) -> Duration:
    return Duration(max(_NO_TIME_LEFT_SECONDS, deadline.at.seconds - deadline.clock.now().seconds))


def _scanned_membership(group: ProcessGroupId, table: ProcessTable, deadline: _Deadline) -> Membership:
    return table_membership(group, table) if table.folder.is_dir() else listing_membership(group, _time_left(deadline))


def _group_answers_probe(group: ProcessGroupId) -> bool:
    try:
        os.killpg(group.number, _PRESENCE_PROBE_SIGNAL)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _group_membership(group: ProcessGroupId, table: ProcessTable, deadline: _Deadline) -> Membership:
    return _scanned_membership(group, table, deadline) if _group_answers_probe(group) else Membership.NO_MEMBER_REMAINS


def _group_ended(led: LedGroup, table: ProcessTable, deadline: _Deadline) -> bool:
    return led.leader.poll() is not None and _group_membership(led.group, table, deadline) is Membership.NO_MEMBER_REMAINS


def kill_group(led: LedGroup) -> None:
    _signal_group(led.group, signal.SIGKILL)


def stop_groups(groups: "frozenset[LedGroup]", grace: Duration, clock: Clock, table: ProcessTable) -> None:
    deadline = _Deadline(Instant(clock.now().seconds + grace.seconds), clock)
    for led in groups:
        _signal_group(led.group, signal.SIGTERM)
    if ending_by(lambda: all(_group_ended(led, table, deadline) for led in groups), deadline.at, clock) is Ending.TIMED_OUT:
        for led in groups:
            kill_group(led)

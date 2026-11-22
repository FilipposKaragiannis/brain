"""Signal a Flow suite's process group and tell whether any member of it is still running."""
import os
import signal
import subprocess
from dataclasses import dataclass
from enum import Enum
from pathlib import Path


PRESENCE_PROBE_SIGNAL = 0
ZOMBIE_STATE = "Z"
STATE_FIELD = 0
PROCESS_GROUP_FIELD = 2
LISTING_GROUP_COLUMN = 0
LISTING_STATE_COLUMN = 1
LISTING_COLUMNS = 2
PROCESS_LISTING_LIMIT_SECONDS = 10


@dataclass(frozen=True)
class ProcessGroupId:
    number: int


@dataclass(frozen=True)
class ProcessTable:
    folder: Path


PROCESS_TABLE = ProcessTable(Path("/proc"))


class Membership(Enum):
    MEMBERS_REMAIN = "members remain"
    NO_MEMBER_REMAINS = "no member remains"
    UNKNOWN = "unknown"


def signal_group(group: ProcessGroupId, sent: signal.Signals) -> bool:
    try:
        os.killpg(group.number, sent)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def _names_group(field: str, group: ProcessGroupId) -> bool:
    return field.isascii() and field.isdigit() and int(field) == group.number


def _membership_of(states: "list[str]") -> Membership:
    live = any(not state.startswith(ZOMBIE_STATE) for state in states)
    return Membership.MEMBERS_REMAIN if live else Membership.NO_MEMBER_REMAINS


def _fields_after_name(status: Path) -> "list[str]":
    try:
        line = status.read_bytes().decode(errors="replace")
    except OSError:
        return []
    return line.rpartition(")")[2].split() if ")" in line else []


def _states_in_process_table(group: ProcessGroupId, statuses: "list[Path]") -> "list[str]":
    rows = (_fields_after_name(status) for status in statuses)
    return [fields[STATE_FIELD] for fields in rows if len(fields) > PROCESS_GROUP_FIELD and _names_group(fields[PROCESS_GROUP_FIELD], group)]


def table_membership(group: ProcessGroupId, table: ProcessTable) -> Membership:
    try:
        with os.scandir(table.folder) as entries:
            statuses = [Path(entry.path, "stat") for entry in entries if entry.name.isascii() and entry.name.isdigit()]
    except OSError:
        return Membership.UNKNOWN
    return _membership_of(_states_in_process_table(group, statuses))


def _states_in_process_listing(group: ProcessGroupId, lines: "list[str]") -> "list[str]":
    rows = (line.split() for line in lines)
    return [row[LISTING_STATE_COLUMN] for row in rows if len(row) == LISTING_COLUMNS and _names_group(row[LISTING_GROUP_COLUMN], group)]


def listing_membership(group: ProcessGroupId) -> Membership:
    try:
        listing = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, timeout=PROCESS_LISTING_LIMIT_SECONDS, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return Membership.UNKNOWN
    if listing.returncode != 0:
        return Membership.UNKNOWN
    return _membership_of(_states_in_process_listing(group, listing.stdout.decode(errors="replace").splitlines()))


def _scanned_membership(group: ProcessGroupId, table: ProcessTable) -> Membership:
    return table_membership(group, table) if table.folder.is_dir() else listing_membership(group)


def _group_answers_probe(group: ProcessGroupId) -> bool:
    try:
        os.killpg(group.number, PRESENCE_PROBE_SIGNAL)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _group_membership(group: ProcessGroupId, table: ProcessTable) -> Membership:
    return _scanned_membership(group, table) if _group_answers_probe(group) else Membership.NO_MEMBER_REMAINS


def group_ended(leader: subprocess.Popen, group: ProcessGroupId, table: ProcessTable) -> bool:
    return leader.poll() is not None and _group_membership(group, table) is Membership.NO_MEMBER_REMAINS

"""Signal a Flow suite's process group and tell whether any member of it is still running."""
import os
import signal
import subprocess
from enum import Enum
from pathlib import Path


PRESENCE_PROBE_SIGNAL = 0
ZOMBIE_STATE = "Z"
PROCESS_TABLE = Path("/proc")
STATE_FIELD = 0
PROCESS_GROUP_FIELD = 2
LISTING_GROUP_COLUMN = 0
LISTING_STATE_COLUMN = 1
LISTING_COLUMNS = 2
PROCESS_LISTING_LIMIT_SECONDS = 10


class Membership(Enum):
    MEMBERS_REMAIN = "members remain"
    NO_MEMBER_REMAINS = "no member remains"
    UNKNOWN = "unknown"


def signal_group(process: subprocess.Popen, number: signal.Signals) -> bool:
    try:
        os.killpg(process.pid, number)
    except (ProcessLookupError, PermissionError):
        return False
    return True


def names_group(field: str, group: int) -> bool:
    return field.isascii() and field.isdigit() and int(field) == group


def membership_of(states: "list[str]") -> Membership:
    live = any(not state.startswith(ZOMBIE_STATE) for state in states)
    return Membership.MEMBERS_REMAIN if live else Membership.NO_MEMBER_REMAINS


def fields_after_name(status: Path) -> "list[str]":
    try:
        line = status.read_bytes().decode(errors="replace")
    except OSError:
        return []
    return line.rpartition(")")[2].split() if ")" in line else []


def states_in_process_table(group: int, statuses: "list[Path]") -> "list[str]":
    rows = (fields_after_name(status) for status in statuses)
    return [fields[STATE_FIELD] for fields in rows if len(fields) > PROCESS_GROUP_FIELD and names_group(fields[PROCESS_GROUP_FIELD], group)]


def table_membership(group: int, table: Path) -> Membership:
    try:
        with os.scandir(table) as entries:
            statuses = [Path(entry.path, "stat") for entry in entries if entry.name.isascii() and entry.name.isdigit()]
    except OSError:
        return Membership.UNKNOWN
    return membership_of(states_in_process_table(group, statuses))


def states_in_process_listing(group: int, lines: "list[str]") -> "list[str]":
    rows = (line.split() for line in lines)
    return [row[LISTING_STATE_COLUMN] for row in rows if len(row) == LISTING_COLUMNS and names_group(row[LISTING_GROUP_COLUMN], group)]


def listing_membership(group: int) -> Membership:
    try:
        listing = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, timeout=PROCESS_LISTING_LIMIT_SECONDS, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return Membership.UNKNOWN
    if listing.returncode != 0:
        return Membership.UNKNOWN
    return membership_of(states_in_process_listing(group, listing.stdout.decode(errors="replace").splitlines()))


def scanned_membership(group: int, table: Path) -> Membership:
    return table_membership(group, table) if table.is_dir() else listing_membership(group)


def group_answers_probe(process: subprocess.Popen) -> bool:
    try:
        os.killpg(process.pid, PRESENCE_PROBE_SIGNAL)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def group_membership(process: subprocess.Popen, table: Path) -> Membership:
    return scanned_membership(process.pid, table) if group_answers_probe(process) else Membership.NO_MEMBER_REMAINS


def group_ended(process: subprocess.Popen, table: Path) -> bool:
    return process.poll() is not None and group_membership(process, table) is Membership.NO_MEMBER_REMAINS

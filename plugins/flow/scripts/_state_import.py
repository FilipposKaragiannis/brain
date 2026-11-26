"""Which open items state.sh import records, skips or strips. Pure: it reads only what it is given.

parsed_lists reads the trackers' lists, one JSON array of adapter items per line. import_rows takes
those items, the slugs of this machine's open records, the slugs of those that do not parse and
the items a pool worktree's claim.json names here, and returns one row per item to record or skip,
then one per item to strip:
  import <item> held|unheld  a candidate with no record; held when its state has a step or a
                             worktree, the state the seed claims for this machine
  skip <item> <why>          a candidate with no record whose worktree no claim here names, or an
                             item with flow state whose record does not parse
  strip <item>               an open item with a record once the imports are in that still carries
                             flow state or a step:, gate:, wt: or flow: label
A candidate is open, has an id of slug shape, and has a tracker state in which a key other than
size holds a value; gate none, attempts 0, empty text and empty lists hold none. A skipped item
gets no strip row, so no tracker loses state that no record here holds. rows_after_writes turns
the import row of an item whose record could not be written into a skip row and drops its strip.
row_text puts a stand-in for each tab, newline or other unprintable character of a field, so tracker
text never splits into a row of its own.
"""
import json
from collections import namedtuple
from collections.abc import Mapping
from types import MappingProxyType
from typing import Optional

import _state_schema as schema
import _state_views as views

IMPORT_ROW, SKIP_ROW, STRIP_ROW = "import", "skip", "strip"
HELD, UNHELD = "held", "unheld"
OPEN_STATUS = "open"
ATTEMPTS_KEY = "attempts"
NO_ATTEMPTS = "0"
FLOW_LABEL_PREFIXES = ("step:", "gate:", "wt:", "flow:")
UNCLAIMED_WHY = "its worktree %s is not claimed on this machine"
UNREADABLE_WHY = "its flow record does not parse"
UNWRITTEN_WHY = "its flow record could not be written"
NOT_LISTS = "import takes one JSON array of adapter items per line on stdin"
NO_STATE = MappingProxyType({})
NO_ROW = None
CLAIM_ITEM_FIELD = "item"
UNPRINTABLE_STAND_IN = "?"

ListedItem = namedtuple("ListedItem", ("id", "open", "state", "labels"))
Listing = namedtuple("Listing", ("items", "problem"))
Row = namedtuple("Row", ("kind", "item", "detail"))


def listed_item(entry: dict) -> ListedItem:
    item_id, state, labels = entry.get("id"), entry.get("state"), entry.get("labels")
    return ListedItem(item_id if isinstance(item_id, str) else "",
                      entry.get("status") == OPEN_STATUS,
                      MappingProxyType(dict(state)) if isinstance(state, dict) else NO_STATE,
                      tuple(label for label in labels if isinstance(label, str)) if isinstance(labels, list) else ())


def parsed_lists(text: str) -> Listing:
    items = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            given = json.loads(line)
        except ValueError:
            return Listing((), NOT_LISTS)
        if not (isinstance(given, list) and all(isinstance(entry, dict) for entry in given)):
            return Listing((), NOT_LISTS)
        items.extend(listed_item(entry) for entry in given)
    return Listing(tuple(items), "")


def claimed_item(claim: Mapping) -> str:
    item = claim.get(CLAIM_ITEM_FIELD)
    return item if isinstance(item, str) else ""


def holds_value(key: str, value: object) -> bool:
    text = views.state_text(value)
    if key == views.GATE_KEY:
        return text not in schema.GATE_CLEARED
    if key == ATTEMPTS_KEY:
        return text not in ("", NO_ATTEMPTS)
    return text != ""


def holds_flow_state(state: Mapping) -> bool:
    return any(holds_value(key, state[key]) for key in schema.STATE_KEYS if key in state and key != views.SIZE_KEY)


def carries_flow_state(item: ListedItem) -> bool:
    return holds_flow_state(item.state) or any(label.startswith(FLOW_LABEL_PREFIXES) for label in item.labels)


def is_held(state: Mapping) -> bool:
    return bool(state.get(views.STEP_KEY) or state.get(views.WORKTREE_KEY))


def unreadable_row(item: ListedItem) -> Optional[Row]:
    return Row(SKIP_ROW, item.id, UNREADABLE_WHY) if carries_flow_state(item) else NO_ROW


def claim_row(item: ListedItem, claimed: frozenset) -> Row:
    worktree = views.state_text(item.state.get(views.WORKTREE_KEY))
    if worktree and item.id not in claimed:
        return Row(SKIP_ROW, item.id, UNCLAIMED_WHY % worktree)
    return Row(IMPORT_ROW, item.id, HELD if is_held(item.state) else UNHELD)


def unrecorded_row(item: ListedItem, recorded: frozenset, claimed: frozenset) -> Optional[Row]:
    if schema.item_slug(item.id) in recorded or not holds_flow_state(item.state):
        return NO_ROW
    return claim_row(item, claimed)


def record_row(item: ListedItem, recorded: frozenset, unreadable: frozenset, claimed: frozenset) -> Optional[Row]:
    if schema.item_slug(item.id) in unreadable:
        return unreadable_row(item)
    return unrecorded_row(item, recorded, claimed)


def import_rows(listed: tuple, recorded: frozenset, unreadable: frozenset, claimed: frozenset) -> tuple:
    opened = [item for item in listed if item.open and schema.item_slug_shaped(item.id)]
    first = tuple(row for row in (record_row(item, recorded, unreadable, claimed) for item in opened) if row is not NO_ROW)
    imported = {row.item for row in first if row.kind == IMPORT_ROW}
    stripped = tuple(Row(STRIP_ROW, item.id, "") for item in opened
                     if (schema.item_slug(item.id) in recorded or item.id in imported) and carries_flow_state(item))
    return first + stripped


def rows_after_writes(rows: tuple, unwritten: frozenset) -> tuple:
    return tuple(Row(SKIP_ROW, row.item, UNWRITTEN_WHY) if row.kind == IMPORT_ROW and row.item in unwritten else row
                 for row in rows if not (row.kind == STRIP_ROW and row.item in unwritten))


def printable(field: str) -> str:
    return "".join(character if character.isprintable() else UNPRINTABLE_STAND_IN for character in field)


def row_text(row: Row) -> str:
    return "\t".join(printable(field) for field in row if field)

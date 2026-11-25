"""The flow record laid onto an adapter's item, and the run and gate rows it lists.
Pure: no file, clock or environment is read here.

A joined item is the adapter's item with `state` replaced and `state_from` and `claim` stamped.
From a record: all twenty-one state keys, text "" when unset, attempts a number, touches and changes
lists, gate none when clear (state_from record). With no record: the tracker's state as the adapter
gave it, the empty state when it gave none (state_from tracker), whatever tracker_state is, since
the mode switches the mirror only. A record wins whole, never merged per key. `claim` is the
record's claim object, null with no record or no claim: the ready filter tells held and held
elsewhere by it.
A run row is {"item", ...the run}; a gate row {"gate", "item", ...the gate's record}, only for a
gate that carries notify.sh's record, its time. A gate named alone has no row.
"""
from collections.abc import Mapping
from types import MappingProxyType

import _state_schema as schema

NO_RECORD = MappingProxyType({})
NO_ROW = MappingProxyType({})
STATE_FIELD = "state"
STATE_FROM_FIELD = "state_from"
CLAIM_FIELD = "claim"
FROM_RECORD, FROM_TRACKER = "record", "tracker"
RUN_ROWS, GATE_ROWS = "runs", "gates"
ROW_KINDS = (RUN_ROWS, GATE_ROWS)
GATE_RECORD_NAME, GATE_RECORD_FROM, GATE_RECORD_TIME = "name", "from", "time"
GATE_CLEAR = "none"


def empty_value(kind):
    if kind == schema.NUMBER:
        return 0
    if kind == schema.LIST:
        return []
    if kind == schema.GATE_NAME:
        return GATE_CLEAR
    return ""


def empty_state():
    return {key: empty_value(state_key.kind) for key, state_key in schema.STATE_KEYS.items()}


def record_value(record, state_key):
    value = schema.record_get(record, state_key.key)
    return empty_value(state_key.kind) if value is None else value


def record_state(record):
    return {key: record_value(record, state_key) for key, state_key in schema.STATE_KEYS.items()}


def unrecorded_state(item):
    given = item.get(STATE_FIELD)
    return given if isinstance(given, dict) else empty_state()


def state_source(record):
    return FROM_RECORD if record is not NO_RECORD else FROM_TRACKER


def joined_item(item: dict, record: Mapping) -> dict:
    state = record_state(record) if record is not NO_RECORD else unrecorded_state(item)
    return dict(item, **{STATE_FIELD: state, STATE_FROM_FIELD: state_source(record),
                         CLAIM_FIELD: record.get(CLAIM_FIELD)})


def headed_row(heading, fields, left_out):
    row = dict(heading)
    row.update((field, value) for field, value in fields.items() if field not in left_out and field not in heading)
    return row


def run_row(record):
    run = record.get("run")
    if not isinstance(run, dict):
        return NO_ROW
    return headed_row({schema.RECORD_ITEM_FIELD: record.get(schema.RECORD_ITEM_FIELD, "")}, run, ())


def gate_row(record):
    gate = record.get("gate")
    if not isinstance(gate, dict) or GATE_RECORD_TIME not in gate:
        return NO_ROW
    heading = {schema.NOTIFY_GATE_FIELD: gate.get(GATE_RECORD_NAME, ""),
               schema.RECORD_ITEM_FIELD: record.get(schema.RECORD_ITEM_FIELD, "")}
    return headed_row(heading, gate, (GATE_RECORD_NAME, GATE_RECORD_FROM))


ROW_OF_KIND = MappingProxyType({RUN_ROWS: run_row, GATE_ROWS: gate_row})


def record_row(record, kind):
    return ROW_OF_KIND[kind](record)

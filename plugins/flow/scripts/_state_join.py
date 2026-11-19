"""The flow record laid onto an adapter's item, and the run and gate rows it lists.
Pure: no file, clock or environment is read here.

A joined item is the adapter's item with `state` replaced and `state_from` stamped. From a record:
all twenty state keys, text "" when unset, attempts a number, touches and changes lists, gate none
when clear (state_from record). With no record: the tracker's state as the adapter gave it while
tracker_state is labels, the empty state when it gave none (state_from tracker); the empty state
under none (state_from none). A record wins whole, never merged per key.
A run row is {"item", ...the run}; a gate row {"gate", "item", ...the gate's record}, only for a
gate that carries notify.sh's record, its time. A gate named alone has no row.
"""
from types import MappingProxyType

import _state_schema as schema

NO_RECORD = MappingProxyType({})
NO_ROW = MappingProxyType({})
STATE_FIELD = "state"
STATE_FROM_FIELD = "state_from"
FROM_RECORD, FROM_TRACKER, FROM_NONE = "record", "tracker", "none"
TRACKER_LABELS, TRACKER_NONE = "labels", "none"
TRACKER_STATES = (TRACKER_LABELS, TRACKER_NONE)
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


def unrecorded_state(item, tracker_state):
    given = item.get(STATE_FIELD)
    if tracker_state == TRACKER_LABELS and isinstance(given, dict):
        return given
    return empty_state()


def state_source(record, tracker_state):
    if record is not NO_RECORD:
        return FROM_RECORD
    return FROM_TRACKER if tracker_state == TRACKER_LABELS else FROM_NONE


def joined_item(item, record, tracker_state):
    state = record_state(record) if record is not NO_RECORD else unrecorded_state(item, tracker_state)
    return dict(item, **{STATE_FIELD: state, STATE_FROM_FIELD: state_source(record, tracker_state)})


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

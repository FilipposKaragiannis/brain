"""The flow record of an item as data: its keys, pairs, merge and reads.
Pure: no file, clock or environment is read here.

_state.py is the edge that loads, locks and writes; this module checks pairs, merges and reads
back; _state_views.py seeds a record and renders its views. A pair is `key=text` for one of the
twenty state keys (a dash reads as an underscore) or one of the record pairs `run:=<object|null>`,
`run.step=<text>` and `gate:=<object>`. Pairs apply in the key map's order; a key given twice takes
its last value. Objects that hold only empty fields read null, and lists are never null.
"""
import json
import re
from collections import namedtuple
from types import MappingProxyType

SCHEMA_VERSION = 1
LOCK_RETRY_SECONDS = 0.05
LOCK_TRIES = 200
EXIT_DONE = 0
EXIT_UNREADABLE = 1
EXIT_REFUSED = 1
EXIT_USAGE = 2
EXIT_BUSY = 75

TEXT, NUMBER, LIST, GATE_NAME, GATE_FROM = "text", "number", "list", "gate name", "gate from"
RUN_OBJECT, RUN_STEP, GATE_OBJECT = "run:", "run.step", "gate:"
RECORD_PAIR_KEYS = (RUN_OBJECT, RUN_STEP, GATE_OBJECT)
OBJECT_FIELDS = MappingProxyType({
    "hold": ("by", "reason"),
    "gate": ("name", "from", "message", "time", "host", "options", "raised_by", "answered_by", "condition", "footer"),
    "answer": ("gate", "asked", "text", "at", "pending"),
    "pr": ("url", "host"),
    "claim": ("machine", "host", "claimed_at", "assigned_at", "worktree"),
})
GATE_CLEARED = ("", "none")
RECORD_ITEM_FIELD = "item"
NOTIFY_GATE_FIELD = "gate"
ITEM_SLUG_SHAPE = re.compile(r"[A-Za-z0-9_-]+")
WHOLE_NUMBER_SHAPE = re.compile(r"[0-9]+")


StateKey = namedtuple("StateKey", ("key", "holder", "field", "kind"))


KEY_MAP = (
    StateKey("step", "", "step", TEXT),
    StateKey("profile", "", "profile", TEXT),
    StateKey("attempts", "", "attempts", NUMBER),
    StateKey("touches", "", "touches", LIST),
    StateKey("changes", "", "changes", LIST),
    StateKey("last_event", "", "last_event", TEXT),
    StateKey("base", "", "base", TEXT),
    StateKey("size", "", "size_estimate", TEXT),
    StateKey("worktree", "claim", "worktree", TEXT),
    StateKey("held_by", "hold", "by", TEXT),
    StateKey("held_reason", "hold", "reason", TEXT),
    StateKey("gate", "gate", "name", GATE_NAME),
    StateKey("gate_from", "gate", "from", GATE_FROM),
    StateKey("answered", "answer", "gate", TEXT),
    StateKey("asked", "answer", "asked", TEXT),
    StateKey("answer", "answer", "text", TEXT),
    StateKey("answered_at", "answer", "at", TEXT),
    StateKey("answer_pending", "answer", "pending", TEXT),
    StateKey("pr", "pr", "url", TEXT),
    StateKey("pr_host", "pr", "host", TEXT),
)
STATE_KEYS = MappingProxyType({state_key.key: state_key for state_key in KEY_MAP})
APPLY_ORDER = tuple(state_key.key for state_key in KEY_MAP) + RECORD_PAIR_KEYS


Pair = namedtuple("Pair", ("key", "value"))
RecordPaths = namedtuple("RecordPaths", ("record", "closed", "lock"))
Outcome = namedtuple("Outcome", ("code", "message"))


DONE = Outcome(EXIT_DONE, "")


def item_slug(item):
    return item.replace(":", "-").replace("/", "-").replace("#", "-")


def item_slug_shaped(item):
    return ITEM_SLUG_SHAPE.fullmatch(item_slug(item)) is not None


def whole_number_shaped(text):
    return WHOLE_NUMBER_SHAPE.fullmatch(text) is not None


def record_paths(state_dir, flow_home, item):
    slug = item_slug(item)
    return RecordPaths("%s/%s.json" % (state_dir, slug), "%s/closed/%s.json" % (state_dir, slug),
                       "%s/locks/%s.lock" % (flow_home, slug))


def parse_pair(text):
    key, separator, value = text.partition("=")
    if not separator:
        return Pair("", text)
    if "." in key or key.endswith(":"):
        return Pair(key, value)
    return Pair(key.replace("-", "_"), value)


def pair_problem(pair):
    if pair.key == "":
        return "expected key=value, got %s" % pair.value
    if pair.key in RECORD_PAIR_KEYS:
        return record_pair_problem(pair)
    if pair.key not in STATE_KEYS:
        return "unknown state key %s" % pair.key
    return number_pair_problem(pair)


def number_pair_problem(pair):
    if STATE_KEYS[pair.key].kind == NUMBER and pair.value != "" and not whole_number_shaped(pair.value):
        return "%s takes a whole number, not %s" % (pair.key, pair.value)
    return ""


def record_pair_problem(pair):
    if pair.key == RUN_STEP:
        return ""
    try:
        value = json.loads(pair.value)
    except ValueError:
        return "%s= takes JSON, not %s" % (pair.key, pair.value)
    return run_object_problem(pair, value) or gate_object_problem(pair, value)


def run_object_problem(pair, value):
    if pair.key == RUN_OBJECT and not (value is None or isinstance(value, dict)):
        return "run:= takes the run as a JSON object, or null, not %s" % pair.value
    return ""


def gate_object_problem(pair, value):
    if pair.key == GATE_OBJECT and not names_an_open_gate(value):
        return "gate:= takes the gate's record with its name in %s, not %s" % (NOTIFY_GATE_FIELD, pair.value)
    return ""


def names_an_open_gate(value):
    gate_name = value.get(NOTIFY_GATE_FIELD) if isinstance(value, dict) else None
    return isinstance(gate_name, str) and gate_name not in GATE_CLEARED


def pairs_outcome(pairs):
    if not pairs:
        return Outcome(EXIT_USAGE, "no key=value pair given")
    problems = [problem for problem in (pair_problem(pair) for pair in pairs) if problem]
    if problems:
        return Outcome(EXIT_USAGE, "; ".join(problems))
    if len({pair.key in RECORD_PAIR_KEYS for pair in pairs}) > 1:
        return Outcome(EXIT_USAGE, "a write holds state pairs or record pairs, never both")
    return DONE


def write_outcome(record, pairs):
    last_by_key = {pair.key: pair for pair in pairs}
    if RUN_STEP not in last_by_key:
        return DONE
    run = json.loads(last_by_key[RUN_OBJECT].value) if RUN_OBJECT in last_by_key else record.get("run")
    if run is None:
        return Outcome(EXIT_USAGE, "run.step= needs a run in flight")
    return DONE


def record_outcome(record):
    if not isinstance(record, dict):
        return Outcome(EXIT_UNREADABLE, "the record is not a JSON object")
    version = record.get("v")
    if not isinstance(version, int) or version > SCHEMA_VERSION:
        return Outcome(EXIT_UNREADABLE, "the record has schema %s; this flow reads %d" % (version, SCHEMA_VERSION))
    return DONE


def new_record(item, now):
    return {"v": SCHEMA_VERSION, "item": item, "step": "", "profile": "", "size_estimate": "", "attempts": 0,
            "touches": [], "changes": [], "base": "", "last_event": "", "hold": None, "gate": None,
            "answer": None, "pr": None, "claim": None, "run": None, "pushed": None,
            "created_at": now, "updated_at": now}


def ordered(holder, fields):
    known = OBJECT_FIELDS[holder]
    shaped = {field: fields[field] for field in known if field in fields}
    shaped.update({field: value for field, value in fields.items() if field not in known})
    if all(value in ("", None, []) for value in shaped.values()):
        return None
    return shaped


def with_field(record, holder, field, value):
    changed = dict(record)
    if holder == "":
        changed[field] = value
        return changed
    fields = dict(record.get(holder) or {})
    fields[field] = value
    changed[holder] = ordered(holder, fields)
    return changed


def state_value(state_key, text):
    if state_key.kind == NUMBER:
        return int(text or 0)
    if state_key.kind == LIST:
        return [entry for entry in text.split(",") if entry.strip()]
    return text


def applied_gate_name(record, name):
    if name in GATE_CLEARED:
        return dict(record, gate=None)
    gate = record.get("gate")
    if gate is not None and gate.get("name") == name:
        return record
    return dict(record, gate={"name": name, "from": ""})


def applied_gate_object(record, text):
    fields = {key: value for key, value in json.loads(text).items() if key != RECORD_ITEM_FIELD}
    name = fields.pop(NOTIFY_GATE_FIELD)
    gate = record.get("gate")
    kept_from = gate.get("from", "") if gate is not None and gate.get("name") == name else ""
    return dict(record, gate=ordered("gate", dict(fields, name=name, **{"from": kept_from})))


def applied_run(record, pair):
    if pair.key == RUN_STEP:
        return dict(record, run=dict(record["run"], step=pair.value))
    run = json.loads(pair.value)
    if run is None:
        return dict(record, run=None)
    return dict(record, run={key: value for key, value in run.items() if key != RECORD_ITEM_FIELD})


def applied_pair(record, pair):
    if pair.key in (RUN_OBJECT, RUN_STEP):
        return applied_run(record, pair)
    if pair.key == GATE_OBJECT:
        return applied_gate_object(record, pair.value)
    state_key = STATE_KEYS[pair.key]
    if state_key.kind == GATE_NAME:
        return applied_gate_name(record, pair.value)
    if state_key.kind == GATE_FROM and record.get("gate") is None:
        return record
    return with_field(record, state_key.holder, state_key.field, state_value(state_key, pair.value))


def merged(record, pairs, now):
    last_by_key = {pair.key: pair for pair in pairs}
    for key in APPLY_ORDER:
        if key in last_by_key:
            record = applied_pair(record, last_by_key[key])
    return dict(record, updated_at=now)


def taken(record, machine, host, now):
    claim = record.get("claim") or {}
    if claim.get("machine"):
        return record
    claimed = dict(claim, machine=machine, host=host, claimed_at=now)
    return dict(record, claim=ordered("claim", claimed), updated_at=now)


def claimed_elsewhere(record, machine):
    holder = (record.get("claim") or {}).get("machine", "")
    return holder not in ("", machine)


def path_value(record, path):
    value = record
    for step in path.split("."):
        value = step_value(value, step)
        if value is None:
            return None
    return value


def step_value(value, step):
    if isinstance(value, list):
        return list_step_value(value, step)
    if isinstance(value, dict):
        return value.get(step)
    return None


def list_step_value(values, step):
    return values[int(step)] if whole_number_shaped(step) and int(step) < len(values) else None


def record_get(record, key):
    state_key = STATE_KEYS.get(key.replace("-", "_"))
    if state_key is None:
        return path_value(record, key)
    if state_key.holder == "":
        return record.get(state_key.field)
    value = (record.get(state_key.holder) or {}).get(state_key.field, "")
    if state_key.kind == GATE_NAME and value in GATE_CLEARED:
        return "none"
    return value

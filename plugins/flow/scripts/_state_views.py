"""The flow record's views and its lazy seed. Pure: no file, clock or environment is read here.

The views are the stores the flow read before the records, rendered from a write's pairs and the
merged record, and only for a fact the write names:
  <flow home>/runs/<slug>.json   {"item", ...run}; written by run:=<object> and run.step=, removed
                                 by run:=null
  <flow home>/gates/<slug>.json  {"gate", "item", ...the gate's record as given}; written by
                                 gate:=<object>, removed by gate=none and gate=
  step in the claim.json         from step= or the run's step, which wins; only when the claim
                                 names the item; never removed
A record with no file yet is seeded from the tracker's state but its size (the tracker's own field,
read until the flow's re-size writes an estimate), the gate file (when the tracker shows no gate or
the same one) and the run file. The seed renders no view.
An item with no record lists its run file and its gate file as its rows under either tracker_state,
so a run or gate from before the records still shows.
"""
import json
from collections import namedtuple
from collections.abc import Mapping

import _state_join as join
import _state_schema as schema

STEP_KEY = "step"
SIZE_KEY = "size"
GATE_KEY = "gate"
WORKTREE_KEY = "worktree"
CLAIM_ITEM_FIELD = "item"
RUN_KEYS = (schema.RUN_OBJECT, schema.RUN_STEP)


ViewPaths = namedtuple("ViewPaths", ("run", "gate"))
ClaimFile = namedtuple("ClaimFile", ("path", "content"))
ViewChange = namedtuple("ViewChange", ("path", "content"))
Seed = namedtuple("Seed", ("state", "gate", "run"))


def view_folder(flow_home, kind):
    return "%s/%s" % (flow_home, kind)


def view_paths(flow_home, item):
    slug = schema.item_slug(item)
    return ViewPaths("%s/%s.json" % (view_folder(flow_home, join.RUN_ROWS), slug),
                     "%s/%s.json" % (view_folder(flow_home, join.GATE_ROWS), slug))


def unrecorded_row(view: Mapping) -> Mapping:
    return view if isinstance(view.get(schema.RECORD_ITEM_FIELD), str) else join.NO_ROW


def view_text(content):
    return json.dumps(content, separators=(",", ":"), ensure_ascii=False)


def run_change(path, named, record):
    if not any(key in named for key in RUN_KEYS):
        return None
    run = record.get("run")
    if run is None:
        return ViewChange(path, None)
    return ViewChange(path, dict({schema.RECORD_ITEM_FIELD: record[schema.RECORD_ITEM_FIELD]}, **run))


def gate_change(path, named, record):
    if schema.GATE_OBJECT in named:
        given = json.loads(named[schema.GATE_OBJECT].value)
        heading = {schema.NOTIFY_GATE_FIELD: given[schema.NOTIFY_GATE_FIELD],
                   schema.RECORD_ITEM_FIELD: record[schema.RECORD_ITEM_FIELD]}
        return ViewChange(path, dict(heading, **{key: value for key, value in given.items() if key not in heading}))
    if GATE_KEY in named and named[GATE_KEY].value in schema.GATE_CLEARED:
        return ViewChange(path, None)
    return None


def claim_step(named, record):
    run = record.get("run") or {}
    if any(key in named for key in RUN_KEYS) and isinstance(run.get(STEP_KEY), str):
        return run[STEP_KEY]
    if STEP_KEY in named:
        return record[STEP_KEY]
    return None


def claim_change(claim, named, record):
    step = claim_step(named, record)
    if step is None or claim.content.get(CLAIM_ITEM_FIELD) != record[schema.RECORD_ITEM_FIELD]:
        return None
    return ViewChange(claim.path, dict(claim.content, **{STEP_KEY: step}))


def view_changes(paths, claim, pairs, record):
    named = {pair.key: pair for pair in pairs}
    changes = (run_change(paths.run, named, record), gate_change(paths.gate, named, record),
               claim_change(claim, named, record))
    return [change for change in changes if change is not None]


def state_text(value):
    if isinstance(value, list):
        return ",".join(str(entry) for entry in value)
    return "" if value is None else str(value)


def seed_pairs(seed):
    pairs = [schema.Pair(key, state_text(seed.state[key])) for key in schema.STATE_KEYS
             if key in seed.state and key != SIZE_KEY]
    tracker_gate = state_text(seed.state.get(GATE_KEY))
    if seed.gate and tracker_gate in schema.GATE_CLEARED + (seed.gate.get(schema.NOTIFY_GATE_FIELD),):
        pairs.append(schema.Pair(schema.GATE_OBJECT, json.dumps(seed.gate)))
    if seed.run:
        pairs.append(schema.Pair(schema.RUN_OBJECT, json.dumps(seed.run)))
    return [pair for pair in pairs if not schema.pair_problem(pair)]


def seeded(item, seed, machine, now):
    record = schema.merged(schema.new_record(item, now), seed_pairs(seed), now)
    if seed.state.get(STEP_KEY) or seed.state.get(WORKTREE_KEY):
        record = schema.with_field(record, "claim", "machine", machine)
    return record

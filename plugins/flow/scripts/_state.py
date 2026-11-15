"""The flow record of an item on disk (ADR 0004). lib/state.sh is its one caller; see there.

  _state.py set     --state-dir D --flow-home H --item I --now T --machine M --host N
                    --claim-file F --seed stdin|none -- <pair>...
  _state.py take    --state-dir D --flow-home H --item I --now T --machine M --host N --seed stdin|none
  _state.py get     --state-dir D --flow-home H --item I -- <key>
  _state.py show    --state-dir D --flow-home H --item I
  _state.py archive --state-dir D --flow-home H --item I --machine M

The record is <state dir>/<slug>.json, archived to <state dir>/closed/<slug>.json; its lock is
<flow home>/locks/<slug>.lock. set, take and archive hold the lock for their file work, tried every
LOCK_RETRY_SECONDS up to LOCK_TRIES times, then exit 75. A write goes to a temporary file and is
renamed over the record. With no record yet, set and take start from the item the adapter read,
given on stdin with --seed stdin, and the item's gate and run files (_state_views.seeded). set then
renders the views its pairs name (_state_views), each through a temporary file and a rename; the
claim file is the item's claim.json, or empty for none. A record that does not parse or carries a
schema above this one is refused, exit 1. set checks every pair before it takes the lock (exit 2).
get prints a string raw and anything else as JSON, nothing when the record or the path is absent.
Exit codes: 0 done, 1 unreadable record or refused archive, 2 bad usage or pair, 75 lock busy.
"""
import fcntl
import json
import os
import sys
import time
from collections import namedtuple
from types import MappingProxyType

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _state_arguments as command_line  # noqa: E402
import _state_schema as schema  # noqa: E402
import _state_views as views  # noqa: E402

NO_RECORD = MappingProxyType({})
NO_OBJECT = MappingProxyType({})
StoredRecord = namedtuple("StoredRecord", ("record", "outcome"))


def read_record(path):
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError:
        return StoredRecord(NO_RECORD, schema.DONE)
    try:
        record = json.loads(text)
    except ValueError:
        return StoredRecord(NO_RECORD, schema.Outcome(schema.EXIT_UNREADABLE, "%s does not parse" % path))
    outcome = schema.record_outcome(record)
    if outcome.code:
        return StoredRecord(NO_RECORD, schema.Outcome(outcome.code, "%s: %s" % (path, outcome.message)))
    return StoredRecord(record, schema.DONE)


def replace_file(path, text):
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    temporary = "%s/.%s.%d.tmp" % (folder, os.path.basename(path), os.getpid())
    try:
        with open(temporary, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


def write_record(path, record):
    replace_file(path, json.dumps(record, indent=2, ensure_ascii=False) + "\n")


def read_object(path):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return NO_OBJECT
    return value if isinstance(value, dict) else NO_OBJECT


def apply_view(change):
    if change.content is not None:
        replace_file(change.path, views.view_text(change.content))
        return
    try:
        os.remove(change.path)
    except FileNotFoundError:
        return


def acquired_lock(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    handle = open(path, "a")
    for _ in range(schema.LOCK_TRIES):
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return handle
        except BlockingIOError:
            time.sleep(schema.LOCK_RETRY_SECONDS)
    handle.close()
    return None


def under_lock(paths, action):
    lock = acquired_lock(paths.lock)
    if lock is None:
        return schema.Outcome(schema.EXIT_BUSY, "another write held the lock %s too long" % paths.lock)
    with lock:
        stored = read_record(paths.record)
        if stored.outcome.code:
            return stored.outcome
        return action(stored.record)


def seed_state(source):
    if source != "stdin":
        return {}
    try:
        item = json.loads(sys.stdin.read())
    except ValueError:
        return {}
    state = item.get("state") if isinstance(item, dict) else None
    return state if isinstance(state, dict) else {}


def item_paths(options):
    return schema.record_paths(options.state_dir, options.flow_home, options.item)


def starting_record(record, options, tracker_state):
    if record is not NO_RECORD:
        return record
    paths = views.view_paths(options.flow_home, options.item)
    seed = views.Seed(tracker_state, read_object(paths.gate), read_object(paths.run))
    return views.seeded(options.item, seed, options.machine, options.now)


def not_recorded(options, pairs, outcome):
    keys = ", ".join(pair.key for pair in pairs)
    return schema.Outcome(outcome.code, "%s: not recorded (%s): %s" % (options.item, keys, outcome.message))


def command_set(options):
    pairs = [schema.parse_pair(text) for text in options.pairs]
    outcome = schema.pairs_outcome(pairs)
    if outcome.code:
        return schema.Outcome(outcome.code, "%s: %s" % (options.item, outcome.message))
    tracker_state = seed_state(options.seed)

    def write(record):
        current = starting_record(record, options, tracker_state)
        refused = schema.write_outcome(current, pairs)
        if refused.code:
            return refused
        updated = schema.merged(current, pairs, options.now)
        write_record(item_paths(options).record, updated)
        claim = views.ClaimFile(options.claim_file, read_object(options.claim_file))
        for change in views.view_changes(views.view_paths(options.flow_home, options.item), claim, pairs, updated):
            apply_view(change)
        return schema.DONE

    written = under_lock(item_paths(options), write)
    return written if written.code in (schema.EXIT_DONE, schema.EXIT_USAGE) else not_recorded(options, pairs, written)


def command_take(options):
    tracker_state = seed_state(options.seed)

    def take(record):
        taken = schema.taken(starting_record(record, options, tracker_state), options.machine, options.host, options.now)
        if taken is not record:
            write_record(item_paths(options).record, taken)
        return schema.DONE

    return under_lock(item_paths(options), take)


def command_archive(options):
    paths = item_paths(options)

    def archive(record):
        if record is NO_RECORD:
            return schema.DONE
        if schema.claimed_elsewhere(record, options.machine):
            return schema.Outcome(schema.EXIT_REFUSED, "%s: another machine (%s) holds it; its record stays"
                                  % (options.item, record["claim"]["machine"]))
        os.makedirs(os.path.dirname(paths.closed), exist_ok=True)
        os.replace(paths.record, paths.closed)
        return schema.DONE

    return under_lock(paths, archive)


def command_get(options):
    stored = read_record(item_paths(options).record)
    value = schema.record_get(stored.record, options.key) if stored.record is not NO_RECORD else None
    if isinstance(value, str):
        print(value)
    elif value is not None and value is not False:
        print(json.dumps(value, separators=(",", ":"), ensure_ascii=False))
    return stored.outcome


def command_show(options):
    stored = read_record(item_paths(options).record)
    if stored.outcome.code:
        return stored.outcome
    if stored.record is NO_RECORD:
        return schema.Outcome(schema.EXIT_REFUSED, "%s has no record" % options.item)
    print(json.dumps(stored.record, indent=2, ensure_ascii=False))
    return schema.DONE


COMMANDS = MappingProxyType({"set": command_set, "take": command_take, "get": command_get, "show": command_show,
                             "archive": command_archive})


def main(arguments):
    parsed = command_line.parsed(arguments)
    options = parsed.options
    try:
        outcome = COMMANDS[options.command](options) if not parsed.outcome.code else parsed.outcome
    except OSError as error:
        outcome = schema.Outcome(schema.EXIT_UNREADABLE, "%s: %s" % (options.item, error))
    if outcome.message:
        sys.stderr.write("flow: %s\n" % outcome.message)
    return outcome.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

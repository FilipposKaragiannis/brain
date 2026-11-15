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
given on stdin with --seed stdin (_state_schema.seeded). A record that does not parse or carries a
schema above this one is refused, exit 1. set checks every pair before it takes the lock (exit 2).
get prints a string raw and anything else as JSON, nothing when the record or the path is absent.
Exit codes: 0 done, 1 unreadable record or refused archive, 2 bad usage or pair, 75 lock busy.
"""
import argparse
import fcntl
import json
import os
import sys
import time
from dataclasses import dataclass
from types import MappingProxyType

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _state_schema as schema  # noqa: E402

SEED_SOURCES = ("stdin", "none")
COMMAND_OPTIONS = MappingProxyType({
    "set": ("state-dir", "flow-home", "item", "now", "machine", "host", "claim-file", "seed"),
    "take": ("state-dir", "flow-home", "item", "now", "machine", "host", "seed"),
    "get": ("state-dir", "flow-home", "item"),
    "show": ("state-dir", "flow-home", "item"),
    "archive": ("state-dir", "flow-home", "item", "machine"),
})
COMMAND_POSITIONALS = MappingProxyType({"set": ("pairs", "*"), "get": ("key", None)})
NO_RECORD = MappingProxyType({})


@dataclass(frozen=True)
class StoredRecord:
    record: dict
    outcome: schema.Outcome


def parsed_options(arguments):
    parser = argparse.ArgumentParser(prog="_state.py")
    commands = parser.add_subparsers(dest="command", required=True)
    for command, options in COMMAND_OPTIONS.items():
        command_parser = commands.add_parser(command)
        for option in options:
            command_parser.add_argument("--" + option, required=True,
                                        choices=SEED_SOURCES if option == "seed" else None)
        if command in COMMAND_POSITIONALS:
            name, count = COMMAND_POSITIONALS[command]
            command_parser.add_argument(name, nargs=count)
    return parser.parse_args(arguments)


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


def write_record(path, record):
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    temporary = "%s/.%s.%d.tmp" % (folder, os.path.basename(path), os.getpid())
    try:
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(record, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)


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
    return schema.seeded(options.item, tracker_state, options.machine, options.now)


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
        write_record(item_paths(options).record, schema.merged(current, pairs, options.now))
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
    options = parsed_options(arguments)
    try:
        outcome = COMMANDS[options.command](options)
    except OSError as error:
        outcome = schema.Outcome(schema.EXIT_UNREADABLE, "%s: %s" % (options.item, error))
    if outcome.message:
        sys.stderr.write("flow: %s\n" % outcome.message)
    return outcome.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

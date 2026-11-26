"""The flow record of an item on disk: read, locked, written and archived here.
lib/state.sh and lib/migrate.sh (import) are its callers; see there.

  _state.py set     --state-dir D --flow-home H --item I --now T --machine M --host N
                    --claim-file F --seed stdin|none -- <pair>...
  _state.py take    --state-dir D --flow-home H --item I --now T --machine M --host N --seed stdin|none
  _state.py get     --state-dir D --flow-home H --item I -- <key>
  _state.py show    --state-dir D --flow-home H --item I
  _state.py status  --state-dir D --flow-home H --item I
  _state.py archive --state-dir D --flow-home H --item I --machine M
  _state.py join|list|row ...  the record laid onto items, and its run and gate rows: _state_reads.py
  _state.py import  --state-dir D --flow-home H --now T --machine M --effect plan|write -- <pool entry>...

The record is <state dir>/<slug>.json, archived to <state dir>/closed/<slug>.json; its lock is
<flow home>/locks/<slug>.lock, and set, take and archive exit 75 when it stays busy. With no record
yet, set and take start from the item the adapter read, given on stdin with --seed stdin, and the
item's gate and run files. set then renders the views its pairs name (_state_views); the claim
file is the item's claim.json, or empty for none. A record that does not parse or carries a schema
above this one is refused, exit 1. A refused pair writes nothing, exit 2.
get prints a string raw and anything else as JSON, nothing when the record or the path is absent.
status prints the tracker status the record stands for (_state_schema.pushed_status), nothing with
no record or no claim.
import reads the trackers' lists on stdin, one JSON array per line, and the claim.json of each pool
entry (a relative one under the flow home's parent), and prints the rows _state_import.py gives,
tab separated. Under write it first seeds the record of each item it imports, under the item's
lock, as set seeds one; an item whose record stays busy is skipped. It exits 1 when a listed
item's record does not parse or one stays busy.
Exit codes: 0 done, 1 unreadable record or refused archive, 2 bad usage or pair, 75 lock busy.
"""
import fcntl
import json
import os
import sys
import time
from collections import namedtuple
from collections.abc import Callable, Mapping
from types import MappingProxyType

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _state_arguments as command_line  # noqa: E402
import _state_import as importing  # noqa: E402
import _state_join as join  # noqa: E402
import _state_reads as reads  # noqa: E402
import _state_schema as schema  # noqa: E402
import _state_views as views  # noqa: E402

NO_RECORD = join.NO_RECORD
NO_OBJECT = MappingProxyType({})
StoredRecord = namedtuple("StoredRecord", ("record", "outcome"))
NEW_FILE_FLAGS = os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW
NEW_FILE_MODE = 0o666
TEMPORARY_NAME_RANDOM_BYTES = 8
CLAIM_PATH = ".flow/claim.json"


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


def replace_file(path, text, random_bytes):
    folder = os.path.dirname(path)
    os.makedirs(folder, exist_ok=True)
    random_suffix = random_bytes(TEMPORARY_NAME_RANDOM_BYTES).hex()
    temporary = "%s/.%s.%d.%s.tmp" % (folder, os.path.basename(path), os.getpid(), random_suffix)
    descriptor = os.open(temporary, NEW_FILE_FLAGS, NEW_FILE_MODE)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.replace(temporary, path)
    finally:
        if os.path.lexists(temporary):
            os.remove(temporary)


def write_record(path, record, random_bytes):
    replace_file(path, json.dumps(record, indent=2, ensure_ascii=False) + "\n", random_bytes)


def read_object(path):
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return NO_OBJECT
    return value if isinstance(value, dict) else NO_OBJECT


def apply_view(change, random_bytes):
    if change.content is not None:
        replace_file(change.path, views.view_text(change.content), random_bytes)
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


def command_set(options, random_bytes):
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
        write_record(item_paths(options).record, updated, random_bytes)
        claim = views.ClaimFile(options.claim_file, read_object(options.claim_file))
        for change in views.view_changes(views.view_paths(options.flow_home, options.item), claim, pairs, updated):
            apply_view(change, random_bytes)
        return schema.DONE

    written = under_lock(item_paths(options), write)
    return written if written.code in (schema.EXIT_DONE, schema.EXIT_USAGE) else not_recorded(options, pairs, written)


def command_take(options, random_bytes):
    tracker_state = seed_state(options.seed)

    def take(record):
        taken = schema.taken(starting_record(record, options, tracker_state), options.machine, options.host, options.now)
        if taken is not record:
            write_record(item_paths(options).record, taken, random_bytes)
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


def command_status(options):
    stored = read_record(item_paths(options).record)
    status = schema.pushed_status(stored.record) if stored.record is not NO_RECORD else schema.NO_STATUS
    if status:
        print(status)
    return stored.outcome


def claimed_items(options: command_line.Options) -> frozenset:
    main_worktree = os.path.dirname(options.flow_home)
    claims = (read_object(os.path.join(main_worktree, entry, CLAIM_PATH)) for entry in options.pool)
    return frozenset(item for item in (importing.claimed_item(claim) for claim in claims) if item)


def stored_records(options: command_line.Options, listed: tuple) -> dict:
    return {item.id: read_record(schema.record_paths(options.state_dir, options.flow_home, item.id).record)
            for item in listed if schema.item_slug_shaped(item.id)}


def seed_imported_record(options: command_line.Options, item: importing.ListedItem,
                         random_bytes: Callable[[int], bytes]) -> schema.Outcome:
    item_options = options._replace(item=item.id)

    def seed(record: Mapping) -> schema.Outcome:
        if record is NO_RECORD:
            write_record(item_paths(item_options).record, starting_record(record, item_options, item.state), random_bytes)
        return schema.DONE

    return under_lock(item_paths(item_options), seed)


def seed_imports(options: command_line.Options, rows: tuple, listed: tuple,
                 random_bytes: Callable[[int], bytes]) -> frozenset:
    if options.effect != command_line.WRITE_EFFECT:
        return frozenset()
    importing_now = {row.item for row in rows if row.kind == importing.IMPORT_ROW}
    unseeded = set()
    for item in (item for item in listed if item.id in importing_now):
        outcome = seed_imported_record(options, item, random_bytes)
        if outcome.code:
            warn("%s: %s" % (item.id, outcome.message))
            unseeded.add(item.id)
    return frozenset(unseeded)


def command_import(options: command_line.Options, random_bytes: Callable[[int], bytes]) -> schema.Outcome:
    listing = importing.parsed_lists(sys.stdin.read())
    if listing.problem:
        return schema.Outcome(schema.EXIT_USAGE, listing.problem)
    stored = stored_records(options, listing.items)
    for each in stored.values():
        if each.outcome.code:
            warn(each.outcome.message)
    recorded = frozenset(schema.item_slug(item) for item, each in stored.items() if each.record is not NO_RECORD)
    unreadable = frozenset(schema.item_slug(item) for item, each in stored.items() if each.outcome.code)
    rows = importing.import_rows(listing.items, recorded, unreadable, claimed_items(options))
    unseeded = seed_imports(options, rows, listing.items, random_bytes)
    for row in importing.rows_after_writes(rows, unseeded):
        print(importing.row_text(row))
    return schema.Outcome(schema.EXIT_UNREADABLE, "") if unreadable or unseeded else schema.DONE


def warn(message):
    sys.stderr.write("flow: %s\n" % message)


def commands(random_bytes):
    edge = reads.Edge(read_record, read_object, sys.stdin.read, warn)
    return MappingProxyType(dict({"set": lambda options: command_set(options, random_bytes),
                                  "take": lambda options: command_take(options, random_bytes),
                                  "get": command_get, "show": command_show, "status": command_status,
                                  "archive": command_archive,
                                  "import": lambda options: command_import(options, random_bytes)},
                                 **reads.commands(edge)))


def main(arguments, random_bytes):
    parsed = command_line.parsed(arguments)
    options = parsed.options
    try:
        outcome = commands(random_bytes)[options.command](options) if not parsed.outcome.code else parsed.outcome
    except OSError as error:
        outcome = schema.Outcome(schema.EXIT_UNREADABLE, "%s: %s" % (options.item, error))
    if outcome.message:
        sys.stderr.write("flow: %s\n" % outcome.message)
    return outcome.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], os.urandom))

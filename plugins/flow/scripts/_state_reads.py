"""The read commands of _state.py that lay the records onto items and list their rows. An edge: it
lists the state dir and the view folders, opens files through the readers _state.py hands it, and
prints; _state_join.py lays the rows and items out, _state_views.py names the view folders.

  _state.py join --state-dir D --flow-home H --tracker-state labels|none
  _state.py list --state-dir D --flow-home H --tracker-state labels|none --kind runs|gates [--item I]
  _state.py row  --state-dir D --flow-home H --tracker-state labels|none --kind runs|gates --item I

join reads an item, or an array of items, on stdin and prints the same shape joined; an item whose
id has no slug shape is unrecorded. list prints one compact row per line, by slug, of every open
record (closed/ is never read), or of the one item given; an item with no record lists its view
file's row (_state_views.py). row prints the item's row, nothing when it has none.
A record that does not parse or carries a newer schema fails join of one item and row, exit 1
naming its file; join of an array and list leave its item out, name the file on stderr and go on.
"""
import json
import os
from collections import namedtuple
from types import MappingProxyType

import _state_join as join
import _state_schema as schema
import _state_views as views

FILE_SUFFIX = ".json"
HIDDEN_PREFIX = "."
ID_FIELD = "id"
NO_ITEM = MappingProxyType({})
NOT_ITEMS = "join takes an item, or an array of items, as JSON on stdin"

Edge = namedtuple("Edge", ("read_record", "read_view", "read_input", "warn"))
Joined = namedtuple("Joined", ("item", "outcome"))
Row = namedtuple("Row", ("row", "outcome"))


def record_path(options, item):
    return schema.record_paths(options.state_dir, options.flow_home, item).record


def joined(item, options, edge):
    item_id = item.get(ID_FIELD)
    if not (isinstance(item_id, str) and schema.item_slug_shaped(item_id)):
        return Joined(join.joined_item(item, join.NO_RECORD, options.tracker_state), schema.DONE)
    stored = edge.read_record(record_path(options, item_id))
    if stored.outcome.code:
        return Joined(NO_ITEM, stored.outcome)
    return Joined(join.joined_item(item, stored.record, options.tracker_state), schema.DONE)


def joined_items(items, options, edge):
    kept = []
    for item in items:
        result = joined(item, options, edge)
        if result.outcome.code:
            edge.warn("%s left out of the list: %s" % (item.get(ID_FIELD), result.outcome.message))
            continue
        kept.append(result.item)
    return kept


def command_join(options, edge):
    try:
        given = json.loads(edge.read_input())
    except ValueError:
        return schema.Outcome(schema.EXIT_USAGE, NOT_ITEMS)
    if isinstance(given, list) and all(isinstance(item, dict) for item in given):
        print(views.view_text(joined_items(given, options, edge)))
        return schema.DONE
    if not isinstance(given, dict):
        return schema.Outcome(schema.EXIT_USAGE, NOT_ITEMS)
    result = joined(given, options, edge)
    if not result.outcome.code:
        print(views.view_text(result.item))
    return result.outcome


def slugs_in(folder):
    try:
        names = os.listdir(folder)
    except FileNotFoundError:
        return set()
    return {name[:-len(FILE_SUFFIX)] for name in names
            if name.endswith(FILE_SUFFIX) and not name.startswith(HIDDEN_PREFIX)
            and os.path.isfile(os.path.join(folder, name))}


def slug_row(slug, options, edge):
    stored = edge.read_record(record_path(options, slug))
    if stored.outcome.code:
        return Row(join.NO_ROW, stored.outcome)
    if stored.record is not join.NO_RECORD:
        return Row(join.record_row(stored.record, options.kind), schema.DONE)
    view = edge.read_view("%s/%s%s" % (views.view_folder(options.flow_home, options.kind), slug, FILE_SUFFIX))
    return Row(views.unrecorded_row(view, options.tracker_state), schema.DONE)


def listed_slugs(options):
    if options.item:
        return [schema.item_slug(options.item)]
    folders = (options.state_dir, views.view_folder(options.flow_home, options.kind))
    return sorted(set().union(*(slugs_in(folder) for folder in folders)))


def command_list(options, edge):
    for slug in listed_slugs(options):
        result = slug_row(slug, options, edge)
        if result.outcome.code:
            edge.warn("%s left out of the list: %s" % (slug, result.outcome.message))
            continue
        if result.row is not join.NO_ROW:
            print(views.view_text(result.row))
    return schema.DONE


def command_row(options, edge):
    result = slug_row(schema.item_slug(options.item), options, edge)
    if not result.outcome.code and result.row is not join.NO_ROW:
        print(views.view_text(result.row))
    return result.outcome


def commands(edge):
    return {"join": lambda options: command_join(options, edge),
            "list": lambda options: command_list(options, edge),
            "row": lambda options: command_row(options, edge)}

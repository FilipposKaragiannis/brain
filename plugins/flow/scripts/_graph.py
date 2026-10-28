#!/usr/bin/env python3
"""Board graphs, built from the open items every adapter lists. See board.sh.

Usage (stdin: the JSON array of open items from every adapter):
  _graph.py epic <item-id> [--mermaid]
  _graph.py priorities [--mermaid]

epic: the dependency model of one item's open children. Waves (longest-path layering), per-node
metadata and the size-weighted critical path. A child is an item whose parent is the id, so a
GitHub sub-issue, a "Parent #N" line and a local parent key all count. Only direct children are
nodes: a parent of epics shows its epics, not their children.
priorities: every open item that is not an epic, one column per priority, an edge per open
blocker, and the inversions: a blocker in a lower priority column than the item it blocks.

Both read only the adapter item shape (id, kind, title, size, priority, rank, blocked_by,
parent), so a new adapter gets both graphs for free. --mermaid prints a Mermaid flowchart of the
model instead of the JSON. The renderer stays dumb: it formats the model and never recomputes
waves, the critical path or the column order.
"""
import json
import sys

SIZE = {"S": 1, "M": 2, "L": 3}
DEFAULT_SIZE = 2
# The rank an adapter gives an item with no priority, or none at all (the local adapter).
NO_RANK = 999
# One fill per priority column, highest first; every column past the last takes the last.
FILLS = ["#fecaca", "#fed7aa", "#fef08a", "#e5e7eb"]
RED = "#b91c1c"


def state_of(item):
    return item.get("state") or {}


def size_name(item):
    return item.get("size") or state_of(item).get("size", "")


def size_weight(item):
    return SIZE.get(size_name(item), DEFAULT_SIZE)


def priority_order(items):
    """Priority names, highest first: by the best rank an item with that priority has (the
    tracker's order where it has one), then by name. Items with no priority come last."""
    best_rank = {}
    for item in items:
        priority = item.get("priority") or ""
        if priority:
            best_rank[priority] = min(best_rank.get(priority, NO_RANK), item.get("rank", NO_RANK))
    return sorted(best_rank, key=lambda priority: (best_rank[priority], priority)) + [""]


def epic(items, epic_id):
    if not any(item["id"] == epic_id for item in items):
        sys.exit("flow: %s is not an open item" % epic_id)
    children = {item["id"]: item for item in items if item.get("parent") == epic_id}
    order = priority_order(items)
    if not children:
        return {"epic": epic_id, "priorities": order, "waves": {}, "nodes": {}, "criticalPath": []}
    blockers = {child_id: [blocker_id for blocker_id in child.get("blocked_by", []) if blocker_id in children]
                for child_id, child in children.items()}

    # Layer by longest path, not in-degree zero: if A blocks B and A blocks C
    # and B blocks C, then C must be wave 3, not wave 2 — otherwise an edge
    # from B to C would point backwards (later wave to earlier wave) on render.
    # A pass that still moves a node after one pass per node means a cycle.
    wave = {child_id: 1 for child_id in children}
    for _ in range(len(children) + 1):
        changed = False
        for child_id in children:
            want = 1 + max((wave[blocker_id] for blocker_id in blockers[child_id]), default=0)
            if want > wave[child_id]:
                wave[child_id] = want
                changed = True
        if not changed:
            break
    else:
        stuck = sorted(child_id for child_id in children if wave[child_id] > len(children))
        sys.exit("flow: the blockers among the children of %s form a cycle. On it or after it: %s" % (epic_id, ", ".join(stuck)))

    unblocks = {child_id: [] for child_id in children}
    for child_id in children:
        for blocker_id in blockers[child_id]:
            unblocks[blocker_id].append(child_id)

    # Critical path: size-weighted (S=1/M=2/L=3) longest chain to the
    # terminal (highest-cost) node, walked back one max-cost blocker at a time.
    cost = {}
    for child_id in sorted(children, key=lambda child_id: wave[child_id]):
        cost[child_id] = size_weight(children[child_id]) + max(
            (cost[blocker_id] for blocker_id in blockers[child_id]), default=0)

    end = max(sorted(cost), key=cost.get)
    path, current = [end], end
    while blockers[current]:
        current = max(blockers[current], key=cost.get)
        path.append(current)

    return {
        "epic": epic_id,
        "priorities": order,
        "waves": {str(number): sorted(child_id for child_id in children if wave[child_id] == number)
                  for number in sorted(set(wave.values()))},
        "nodes": {
            child_id: {
                "title": child["title"],
                "size": size_weight(child),
                "priority": child.get("priority") or "",
                "blockers": blockers[child_id],
                "leaf": not unblocks[child_id],
                # closeout: to-subissues' verification-closeout naming
                # convention. enabler: unblocks others, blocked by
                # nothing itself. behaviour: everything else.
                "role": (
                    "closeout"
                    if child["title"].startswith("Verify:")
                    else "enabler"
                    if unblocks[child_id] and not blockers[child_id]
                    else "behaviour"
                ),
                # raw label names, passed through undecided — a
                # renderer that cares about a repo-specific label
                # (e.g. a "descope-candidate" convention) reads it
                # here instead of the model guessing at meaning.
                "labels": child.get("labels", []),
            }
            for child_id, child in children.items()
        },
        "criticalPath": sorted(path, key=lambda child_id: wave[child_id]),
    }


def priorities(items):
    open_items = {item["id"]: item for item in items if item.get("kind") != "epic"}
    order = priority_order(items)
    column_of = {item_id: order.index(item.get("priority") or "") for item_id, item in open_items.items()}
    nodes = {
        item_id: {
            "title": item["title"],
            "kind": item.get("kind", ""),
            "size": size_name(item),
            "priority": item.get("priority") or "",
            "step": state_of(item).get("step", ""),
            "gate": state_of(item).get("gate", "none"),
            "blockers": [blocker_id for blocker_id in item.get("blocked_by", []) if blocker_id in open_items],
        }
        for item_id, item in open_items.items()
    }
    return {
        "priorities": order,
        "columns": [{"priority": priority, "items": [item_id for item_id in open_items if column_of[item_id] == index]}
                    for index, priority in enumerate(order) if index in column_of.values()],
        "nodes": nodes,
        "inversions": [[blocker_id, item_id] for item_id in open_items for blocker_id in nodes[item_id]["blockers"]
                       if column_of[blocker_id] > column_of[item_id]],
    }


def label(text):
    """Mermaid label text: #, quotes and angle brackets as entities, so a title cannot end the
    label or read as an entity itself ("Fix #12; crash")."""
    return str(text).replace("#", "#35;").replace('"', "#quot;").replace("<", "#lt;").replace(">", "#gt;")


def node_ids(model):
    return {item_id: "n%d" % number for number, item_id in enumerate(sorted(model["nodes"]), 1)}


def node_line(node_id, item_id, title, details):
    shown = " · ".join(detail for detail in details if detail)
    return '    %s["%s %s<br/>%s"]' % (node_id, label(item_id), label(title), label(shown))


def flowchart(model, details, columns, edges, empty):
    """The flowchart both graphs share. details: item id to the words under its title. columns:
    (subgraph id, title, item ids). edges: (blocker id, item id, arrow, red); the red ones get
    one linkStyle, by their order. Returns the lines and the node ids."""
    ids = node_ids(model)
    lines = ["flowchart LR"]
    if not ids:
        lines.append('  empty["%s"]' % label(empty))
        return lines, ids
    for subgraph_id, title, item_ids in columns:
        lines.append('  subgraph %s["%s"]' % (subgraph_id, label(title)))
        lines.extend(node_line(ids[item_id], item_id, model["nodes"][item_id]["title"], details[item_id])
                     for item_id in item_ids)
        lines.append("  end")
    red_edges = []
    for index, (blocker_id, item_id, arrow, is_red) in enumerate(edges):
        lines.append("  %s %s %s" % (ids[blocker_id], arrow, ids[item_id]))
        if is_red:
            red_edges.append(str(index))
    lines.extend(priority_classes(model, ids))
    if red_edges:
        lines.append("  linkStyle %s stroke:%s,stroke-width:3px" % (",".join(red_edges), RED))
    return lines, ids


def priority_classes(model, ids):
    """One fill per priority in the board-wide order, highest first, so a priority has the same
    fill in both graphs. Black text, so it reads in a dark theme too."""
    lines = []
    for index, priority in enumerate(priority for priority in model["priorities"] if priority):
        members = [ids[item_id] for item_id in sorted(model["nodes"]) if model["nodes"][item_id]["priority"] == priority]
        if members:
            lines.append("  classDef priority%d fill:%s,color:#000" % (index, FILLS[min(index, len(FILLS) - 1)]))
            lines.append("  class %s priority%d" % (",".join(members), index))
    return lines


def blocker_edges(model):
    return [(blocker_id, item_id) for item_id in sorted(model["nodes"]) for blocker_id in model["nodes"][item_id]["blockers"]]


def mermaid_epic(model):
    critical = set(zip(model["criticalPath"], model["criticalPath"][1:]))
    lines, ids = flowchart(
        model,
        {item_id: ("SML"[node["size"] - 1], node["priority"]) for item_id, node in model["nodes"].items()},
        [("wave" + number, "Wave " + number, item_ids) for number, item_ids in model["waves"].items()],
        [(blocker_id, item_id, "==>" if (blocker_id, item_id) in critical else "-->", (blocker_id, item_id) in critical)
         for blocker_id, item_id in blocker_edges(model)],
        "%s has no open children" % model["epic"])
    if ids:
        lines.append("  classDef critical stroke:%s,stroke-width:3px" % RED)
        lines.append("  class %s critical" % ",".join(ids[item_id] for item_id in model["criticalPath"]))
    return "\n".join(lines)


def mermaid_priorities(model):
    inverted = {tuple(pair) for pair in model["inversions"]}
    lines, _ = flowchart(
        model,
        {item_id: (node["kind"], node["size"], node["step"], "gate " + node["gate"] if node["gate"] != "none" else "")
         for item_id, node in model["nodes"].items()},
        [("column%d" % index, column["priority"] or "no priority", column["items"])
         for index, column in enumerate(model["columns"])],
        [(blocker_id, item_id, "-. inversion .->" if (blocker_id, item_id) in inverted else "-->", (blocker_id, item_id) in inverted)
         for blocker_id, item_id in blocker_edges(model)],
        "no open items")
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    as_mermaid = "--mermaid" in args
    args = [arg for arg in args if arg != "--mermaid"]
    items = json.load(sys.stdin)
    if args[:1] == ["epic"] and len(args) == 2:
        model = epic(items, args[1])
        print(mermaid_epic(model) if as_mermaid else json.dumps(model, indent=2))
    elif args == ["priorities"]:
        model = priorities(items)
        print(mermaid_priorities(model) if as_mermaid else json.dumps(model, indent=2))
    else:
        sys.exit("usage: _graph.py epic <item-id> [--mermaid] | priorities [--mermaid]")


if __name__ == "__main__":
    main()

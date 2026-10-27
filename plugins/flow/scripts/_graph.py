#!/usr/bin/env python3
"""Board graphs, built from the open items every adapter lists. See board.sh.

Usage (stdin: the JSON array of open items from every adapter):
  _graph.py epic <item-id> [--mermaid]
  _graph.py priorities [--mermaid]

epic: the dependency model of one item's open children. Waves (longest-path layering), per-node
metadata and the size-weighted critical path. A child is an item whose parent is the id, so a
GitHub sub-issue, a "Parent #N" line and a local parent key all count.
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
# One fill per priority column, highest first; every column past the last takes the last.
FILLS = ["#fecaca", "#fed7aa", "#fef08a", "#e5e7eb"]


def size_of(item):
    return SIZE.get(item.get("size") or item.get("state", {}).get("size", ""), 2)


def priority_order(items):
    """Priority names, highest first: by the best rank an item with that priority has (the
    tracker's order where it has one), then by name. Items with no priority come last."""
    best = {}
    for i in items:
        p = i.get("priority") or ""
        if p:
            best[p] = min(best.get(p, 999), i.get("rank", 999))
    return sorted(best, key=lambda p: (best[p], p)) + [""]


def epic(items, epic_id):
    if not any(i["id"] == epic_id for i in items):
        sys.exit("flow: %s is not an open item" % epic_id)
    open_ = {i["id"]: i for i in items if i.get("parent") == epic_id}
    order = priority_order(items)
    if not open_:
        return {"epic": epic_id, "priorities": order, "waves": {}, "nodes": {}, "criticalPath": []}
    blockers = {k: [b for b in i.get("blocked_by", []) if b in open_] for k, i in open_.items()}

    # Layer by longest path, not in-degree zero: if A blocks B and A blocks C
    # and B blocks C, then C must be wave 3, not wave 2 — otherwise an edge
    # from B to C would point backwards (later wave to earlier wave) on render.
    # A pass that still moves a node after one pass per node means a cycle.
    wave = {k: 1 for k in open_}
    for _ in range(len(open_) + 1):
        changed = False
        for k in open_:
            want = 1 + max((wave[b] for b in blockers[k]), default=0)
            if want > wave[k]:
                wave[k] = want
                changed = True
        if not changed:
            break
    else:
        stuck = sorted(k for k in open_ if wave[k] > len(open_))
        sys.exit("flow: the blockers among the children of %s form a cycle. On it or after it: %s" % (epic_id, ", ".join(stuck)))

    succ = {k: [] for k in open_}
    for k in open_:
        for b in blockers[k]:
            succ[b].append(k)

    # Critical path: size-weighted (S=1/M=2/L=3) longest chain to the
    # terminal (highest-cost) node, walked back one max-cost blocker at a time.
    cost = {}
    for k in sorted(open_, key=lambda x: wave[x]):
        cost[k] = size_of(open_[k]) + max((cost[b] for b in blockers[k]), default=0)

    end = max(sorted(cost), key=cost.get)
    path, cur = [end], end
    while blockers[cur]:
        cur = max(blockers[cur], key=cost.get)
        path.append(cur)

    return {
        "epic": epic_id,
        "priorities": order,
        "waves": {str(w): sorted(k for k in open_ if wave[k] == w) for w in sorted(set(wave.values()))},
        "nodes": {
            k: {
                "title": i["title"],
                "size": size_of(i),
                "priority": i.get("priority") or "",
                "blockers": blockers[k],
                "leaf": not succ[k],
                # closeout: to-subissues' verification-closeout naming
                # convention. enabler: unblocks others, blocked by
                # nothing itself. behaviour: everything else.
                "kind": (
                    "closeout"
                    if i["title"].startswith("Verify:")
                    else "enabler"
                    if succ[k] and not blockers[k]
                    else "behaviour"
                ),
                # raw label names, passed through undecided — a
                # renderer that cares about a repo-specific label
                # (e.g. a "descope-candidate" convention) reads it
                # here instead of the model guessing at meaning.
                "labels": i.get("labels", []),
            }
            for k, i in open_.items()
        },
        "criticalPath": sorted(path, key=lambda k: wave[k]),
    }


def priorities(items):
    open_ = {i["id"]: i for i in items if i.get("kind") != "epic"}
    order = priority_order(items)
    column = {k: order.index(i.get("priority") or "") for k, i in open_.items()}
    nodes = {
        k: {
            "title": i["title"],
            "kind": i.get("kind", ""),
            "size": i.get("size") or i.get("state", {}).get("size", ""),
            "priority": i.get("priority") or "",
            "step": i.get("state", {}).get("step", ""),
            "gate": i.get("state", {}).get("gate", "none"),
            "blockers": [b for b in i.get("blocked_by", []) if b in open_],
        }
        for k, i in open_.items()
    }
    return {
        "priorities": order,
        "columns": [{"priority": p, "items": [k for k in open_ if column[k] == n]}
                    for n, p in enumerate(order) if any(column[k] == n for k in open_)],
        "nodes": nodes,
        "inversions": [[b, k] for k in open_ for b in nodes[k]["blockers"] if column[b] > column[k]],
    }


def label(text):
    """Mermaid label text: #, quotes and angle brackets as entities, so a title cannot end the
    label or read as an entity itself ("Fix #12; crash")."""
    return str(text).replace("#", "#35;").replace('"', "#quot;").replace("<", "#lt;").replace(">", "#gt;")


def mermaid_epic(m):
    ids = {k: "n%d" % n for n, k in enumerate(sorted(m["nodes"]), 1)}
    lines = ["flowchart LR"]
    if not ids:
        lines.append('  empty["%s has no open children"]' % label(m["epic"]))
        return "\n".join(lines)
    for w, keys in m["waves"].items():
        lines.append('  subgraph wave%s["Wave %s"]' % (w, w))
        for k in keys:
            n = m["nodes"][k]
            meta = " · ".join(x for x in ("SML"[n["size"] - 1], n["priority"]) if x)
            lines.append('    %s["%s %s<br/>%s"]' % (ids[k], label(k), label(n["title"]), label(meta)))
        lines.append("  end")
    critical = set(zip(m["criticalPath"], m["criticalPath"][1:]))
    for k in sorted(m["nodes"]):
        for b in m["nodes"][k]["blockers"]:
            lines.append("  %s %s %s" % (ids[b], "==>" if (b, k) in critical else "-->", ids[k]))
    lines.extend(classes(m["priorities"], {k: n["priority"] for k, n in m["nodes"].items()}, ids))
    lines.append("  classDef critical stroke:#b91c1c,stroke-width:3px")
    lines.append("  class %s critical" % ",".join(ids[k] for k in m["criticalPath"]))
    return "\n".join(lines)


def mermaid_priorities(m):
    ids = {k: "n%d" % n for n, k in enumerate(sorted(m["nodes"]), 1)}
    lines = ["flowchart LR"]
    if not ids:
        lines.append('  empty["no open items"]')
        return "\n".join(lines)
    for n, col in enumerate(m["columns"]):
        lines.append('  subgraph p%d["%s"]' % (n, label(col["priority"] or "no priority")))
        for k in col["items"]:
            node = m["nodes"][k]
            meta = " · ".join(x for x in (node["kind"], node["size"], node["step"],
                                          "gate " + node["gate"] if node["gate"] != "none" else "") if x)
            lines.append('    %s["%s %s<br/>%s"]' % (ids[k], label(k), label(node["title"]), label(meta)))
        lines.append("  end")
    inverted = {tuple(x) for x in m["inversions"]}
    edge, red = 0, []
    for k in sorted(m["nodes"]):
        for b in m["nodes"][k]["blockers"]:
            if (b, k) in inverted:
                lines.append("  %s -. inversion .-> %s" % (ids[b], ids[k]))
                red.append(str(edge))
            else:
                lines.append("  %s --> %s" % (ids[b], ids[k]))
            edge += 1
    lines.extend(classes(m["priorities"], {k: n["priority"] for k, n in m["nodes"].items()}, ids))
    if red:
        lines.append("  linkStyle %s stroke:#b91c1c,stroke-width:2px" % ",".join(red))
    return "\n".join(lines)


def classes(order, priority_of, ids):
    """One fill per priority in the board-wide order, highest first, so a priority has the same
    fill in both graphs. Black text, so it reads in a dark theme too."""
    out = []
    for n, p in enumerate(x for x in order if x):
        keys = [ids[k] for k in sorted(priority_of) if priority_of[k] == p]
        if keys:
            out.append("  classDef prio%d fill:%s,color:#000" % (n, FILLS[min(n, len(FILLS) - 1)]))
            out.append("  class %s prio%d" % (",".join(keys), n))
    return out


def main():
    args = sys.argv[1:]
    as_mermaid = "--mermaid" in args
    args = [a for a in args if a != "--mermaid"]
    items = json.load(sys.stdin)
    if args[:1] == ["epic"] and len(args) == 2:
        m = epic(items, args[1])
        print(mermaid_epic(m) if as_mermaid else json.dumps(m, indent=2))
    elif args == ["priorities"]:
        m = priorities(items)
        print(mermaid_priorities(m) if as_mermaid else json.dumps(m, indent=2))
    else:
        sys.exit("usage: _graph.py epic <item-id> [--mermaid] | priorities [--mermaid]")


if __name__ == "__main__":
    main()

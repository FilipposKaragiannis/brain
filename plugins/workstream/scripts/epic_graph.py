#!/usr/bin/env python3
"""Build the JSON dependency-graph model for one epic's open sub-issues.

Usage: epic_graph.py <owner/repo> <epic#>

Emits a JSON model on stdout — waves (longest-path layering), per-node
metadata, and the size-weighted critical path. Renderers (board's SVG view
and its Mermaid comment) stay dumb: they only format this model, they never
recompute waves or the critical path themselves. Two renderers, one model —
that's the whole point.
"""
import json
import subprocess
import sys

SIZE = {"size:S": 1, "size:M": 2, "size:L": 3}


def gh(*args):
    return json.loads(subprocess.check_output(["gh", *args]))


def main():
    if len(sys.argv) != 3:
        print("usage: epic_graph.py <owner/repo> <epic#>", file=sys.stderr)
        sys.exit(1)

    repo, epic = sys.argv[1], sys.argv[2]

    q = (
        '{ repository(owner:"%s", name:"%s"){ issue(number:%s){ '
        "subIssues(first:100){ nodes{ number state title "
        "labels(first:20){nodes{name}} } } } } }"
    )
    resp = gh("api", "graphql", "-f", "query=" + q % (*repo.split("/"), epic))
    nodes = resp["data"]["repository"]["issue"]["subIssues"]["nodes"]

    open_ = {n["number"]: n for n in nodes if n["state"] == "OPEN"}

    if not open_:
        print(json.dumps({"waves": {}, "nodes": {}, "criticalPath": []}, indent=2))
        return

    for n in open_.values():
        n["labelNames"] = [l["name"] for l in n["labels"]["nodes"]]
        n["size"] = next((SIZE[l] for l in n["labelNames"] if l in SIZE), 2)
        dep = gh("api", f"repos/{repo}/issues/{n['number']}/dependencies/blocked_by")
        n["blockers"] = [d["number"] for d in dep if d["number"] in open_]

    # Layer by longest path, not in-degree zero: if A blocks B and A blocks C
    # and B blocks C, then C must be wave 3, not wave 2 — otherwise an edge
    # from B to C would point backwards (later wave to earlier wave) on render.
    wave = {k: 1 for k in open_}
    changed = True
    while changed:
        changed = False
        for k, n in open_.items():
            want = 1 + max((wave[b] for b in n["blockers"]), default=0)
            if want > wave[k]:
                wave[k] = want
                changed = True

    succ = {k: [] for k in open_}
    for k, n in open_.items():
        for b in n["blockers"]:
            succ[b].append(k)

    # Critical path: size-weighted (S=1/M=2/L=3) longest chain to the
    # terminal (highest-cost) node, walked back one max-cost blocker at a time.
    cost = {}
    for k in sorted(open_, key=lambda x: wave[x]):
        cost[k] = open_[k]["size"] + max(
            (cost[b] for b in open_[k]["blockers"]), default=0
        )

    end = max(cost, key=cost.get)
    path, cur = [end], end
    while open_[cur]["blockers"]:
        cur = max(open_[cur]["blockers"], key=cost.get)
        path.append(cur)

    print(
        json.dumps(
            {
                "waves": {
                    str(w): sorted(k for k in open_ if wave[k] == w)
                    for w in sorted(set(wave.values()))
                },
                "nodes": {
                    str(k): {
                        "title": open_[k]["title"],
                        "size": open_[k]["size"],
                        "blockers": open_[k]["blockers"],
                        "leaf": not succ[k],
                        # closeout: to-subissues' verification-closeout naming
                        # convention. enabler: unblocks others, blocked by
                        # nothing itself. behaviour: everything else.
                        "kind": (
                            "closeout"
                            if open_[k]["title"].startswith("Verify:")
                            else "enabler"
                            if succ[k] and not open_[k]["blockers"]
                            else "behaviour"
                        ),
                        # raw label names, passed through undecided — a
                        # renderer that cares about a repo-specific label
                        # (e.g. a "descope-candidate" convention) reads it
                        # here instead of the model guessing at meaning.
                        "labels": open_[k]["labelNames"],
                    }
                    for k in open_
                },
                "criticalPath": sorted(path, key=lambda k: wave[k]),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()

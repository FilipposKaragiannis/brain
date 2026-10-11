"""Board renderer. See board.sh."""
import json, sys
as_json, pool_text = sys.argv[1] == "1", sys.argv[2]
items, runs, gates = (json.loads(l) for l in sys.stdin.read().split("\n")[:3])
pool = []
for line in pool_text.splitlines():
    parts = line.split(None, 4)
    if len(parts) >= 4:
        pool.append({"worktree": parts[0], "branch": parts[1], "item": parts[2] if parts[2] != "-" else "",
                     "step": parts[3] if parts[3] != "-" else "", "state": parts[4] if len(parts) > 4 else ""})
by_id = {i["id"]: i for i in items}
running = {r["item"]: r for r in runs}
def overlaps(a, b):
    for x in a:
        for y in b:
            px, py = x.split("*", 1)[0], y.split("*", 1)[0]
            if px.startswith(py) or py.startswith(px): return True
    return False
claimed = [i for i in items if i["state"].get("worktree")]
overlap = []
for n, a in enumerate(claimed):
    for b in claimed[n + 1:]:
        if overlaps(a["state"].get("touches", []), b["state"].get("touches", [])):
            overlap.append((a["id"], b["id"]))
if as_json:
    print(json.dumps({"pool": pool, "items": items, "runs": runs, "gates": gates,
                      "overlaps": [list(o) for o in overlap]}, indent=2)); sys.exit()
print("## Pool")
print("| worktree | branch | item | step | last event | state |")
print("|---|---|---|---|---|---|")
for p in pool:
    it = by_id.get(p["item"], {})
    ev = it.get("state", {}).get("last_event", "")
    run = " (running on %s)" % running[p["item"]]["host"] if p["item"] in running else ""
    print("| %s | %s | %s | %s | %s | %s%s |" % (p["worktree"], p["branch"], p["item"] or "-", p["step"] or "-", ev, p["state"], run))
print("\n## Items")
print("| item | kind | size | title | step | gate | worktree | blocked by |")
print("|---|---|---|---|---|---|---|---|")
for i in items:
    s = i["state"]
    print("| %s | %s | %s | %s | %s | %s | %s | %s |" % (i["id"], i["kind"], i.get("size") or s.get("size", ""), i["title"][:50],
          s.get("step") or "-", s.get("gate") or "none", s.get("worktree") or "-", ", ".join(i.get("blocked_by", [])) or "-"))
if gates:
    print("\n## Waiting on you")
    for g in gates:
        print("- **%s** on %s (%s): %s" % (g["gate"], g["item"], g["time"], g["message"].splitlines()[0] if g["message"] else ""))
if overlap:
    print("\n## Overlapping claims")
    for a, b in overlap:
        print("- %s and %s touch the same paths" % (a, b))

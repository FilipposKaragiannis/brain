"""Board renderer. See board.sh."""
import calendar, json, sys, time
as_json, pool_text, reminder = sys.argv[1] == "1", sys.argv[2], int(sys.argv[3])
items, runs, gates = (json.loads(l) for l in sys.stdin.read().split("\n")[:3])
pool = []
for line in pool_text.splitlines():
    parts = line.split(None, 4)
    if len(parts) >= 4:
        pool.append({"worktree": parts[0], "branch": parts[1], "item": parts[2] if parts[2] != "-" else "",
                     "step": parts[3] if parts[3] != "-" else "", "state": parts[4] if len(parts) > 4 else ""})
by_id = {i["id"]: i for i in items}
running = {r["item"]: r for r in runs}
def epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return 0
def age(seconds):
    seconds = int(seconds)
    if seconds < 3600: return "%dm" % (seconds // 60)
    if seconds < 86400: return "%dh %02dm" % (seconds // 3600, seconds % 3600 // 60)
    return "%dd %dh" % (seconds // 86400, seconds % 86400 // 3600)
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
    run = ""
    if p["item"] in running:
        r = running[p["item"]]
        run = " (running on %s)" % r["host"] if r["alive"] else " (run starting)" if r["starting"] else " (dead run)"
    print("| %s | %s | %s | %s | %s | %s%s |" % (p["worktree"], p["branch"], p["item"] or "-", p["step"] or "-", ev, p["state"], run))
print("\n## Items")
print("| item | kind | priority | size | title | step | gate | worktree | blocked by |")
print("|---|---|---|---|---|---|---|---|---|")
def step_of(i):
    step = i["state"].get("step") or "-"
    if step == "split":
        kids = i.get("open_children", 0)
        return "split, waiting on %d child%s" % (kids, "" if kids == 1 else "ren") if kids else "split, every child closed"
    return step
for i in sorted(items, key=lambda i: i.get("rank", 999)):
    s = i["state"]
    print("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (i["id"], i["kind"], i.get("priority", ""), i.get("size") or s.get("size", ""), i["title"][:50],
          step_of(i), s.get("gate") or "none", s.get("worktree") or "-", ", ".join(i.get("blocked_by", [])) or "-"))
if gates:
    print("\n## Waiting on you")
    for g in gates:
        print("- **%s** on %s (%s): %s" % (g["gate"], g["item"], g["time"], str(g["message"]).splitlines()[0] if g["message"] != "" else ""))
now = time.time()
waiting = [g for g in gates if now - epoch(g["time"]) > reminder]
dead = [r for r in runs if not r["alive"] and not r["starting"]]
if dead or waiting:
    print("\n## Health")
    for r in dead:
        print("- %s: dead run of %s, no process since the record was written (%s ago)" % (r["item"], r["step"], age(r["age"])))
    for g in waiting:
        print("- %s: waiting %s at the %s gate" % (g["item"], age(now - epoch(g["time"])), g["gate"]))
if overlap:
    print("\n## Overlapping claims")
    for a, b in overlap:
        print("- %s and %s touch the same paths" % (a, b))

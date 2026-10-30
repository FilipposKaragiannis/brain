"""Board renderer. See board.sh."""
import calendar, json, os, sys, time
as_json, pool_text, reminder = sys.argv[1] == "1", sys.argv[2], int(sys.argv[3])
log = sys.argv[4] if len(sys.argv) > 4 else ""
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
# The spend per item: the step session lines in runs.jsonl (lib/host.sh host_record), the cost
# the host reported summed, with the session count and the tokens. Codex reports no cost.
spend = {}
for name in ("runs.1.jsonl", "runs.jsonl"):
    path = os.path.join(log, name)
    for line in open(path, errors="replace") if log and os.path.exists(path) else []:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not isinstance(r, dict) or "job" in r or not isinstance(r.get("item"), str) or not r.get("step"):
            continue
        s = spend.setdefault(r["item"], {"cost_usd": 0.0, "sessions": 0, "tokens": 0})
        s["sessions"] += 1
        if isinstance(r.get("cost_usd"), (int, float)):
            s["cost_usd"] = round(s["cost_usd"] + r["cost_usd"], 6)
        u = r.get("usage") if isinstance(r.get("usage"), dict) else {}
        s["tokens"] += sum(v for k, v in u.items() if k.endswith("tokens") and isinstance(v, int))
if as_json:
    print(json.dumps({"pool": pool, "items": items, "runs": runs, "gates": gates,
                      "overlaps": [list(o) for o in overlap], "spend": spend}, indent=2)); sys.exit()
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
if spend:
    print("\n## Spend (unattended step sessions)")
    print("| item | cost | sessions | tokens |")
    print("|---|---|---|---|")
    for item, s in sorted(spend.items(), key=lambda kv: -kv[1]["cost_usd"]):
        print("| %s | $%.2f | %d | %d |" % (item, s["cost_usd"], s["sessions"], s["tokens"]))
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

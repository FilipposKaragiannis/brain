"""Board renderer. See board.sh."""
import calendar, json, os, sys, time
as_json, pool_text, reminder = sys.argv[1] == "1", sys.argv[2], int(sys.argv[3])
log = sys.argv[4] if len(sys.argv) > 4 else ""
lines = sys.stdin.read().split("\n")
items, runs, gates = (json.loads(l) for l in lines[:3])
# Each tracker whose list failed: {"tracker", "code", "message"}, the adapter's last stderr line.
tracker_errors = json.loads(lines[3]) if len(lines) > 3 and lines[3].strip() else []
holders = json.loads(lines[4]) if len(lines) > 4 and lines[4].strip() else []
pool = []
for line in pool_text.splitlines():
    parts = line.split(None, 4)
    if len(parts) >= 4:
        pool.append({"worktree": parts[0], "branch": parts[1], "item": parts[2] if parts[2] != "-" else "",
                     "step": parts[3] if parts[3] != "-" else "", "state": parts[4] if len(parts) > 4 else ""})
# Each blocker the lists leave out, as board.sh read it: {"id", "status"}, status open, closed or unknown.
read_blockers = json.loads(lines[5]) if len(lines) > 5 and lines[5].strip() else []
# The base each claimed pool worktree records, as board.sh read it: {"item", "base", "missing"},
# missing when the repository has an origin that lacks the branch.
claimed_list = json.loads(lines[6]) if len(lines) > 6 and lines[6].strip() else []
claimed_bases = {claimed["item"]: claimed for claimed in claimed_list}
config_base = os.environ.get("FLOW_CONFIG_BASE", "")
for pool_entry in pool:
    claimed = claimed_bases.get(pool_entry["item"], {})
    pool_entry["base"], pool_entry["base_missing"] = claimed.get("base", ""), claimed.get("missing", False)
by_id = {i["id"]: i for i in items}
status_of = {blocker["id"]: blocker["status"] for blocker in read_blockers}
status_of.update((item["id"], item.get("status", "open")) for item in items)
# Only a blocker the tracker says is closed holds nothing; one it cannot read still holds, as in next.sh.
for i in items:
    if "open_blockers" not in i:
        i["open_blockers"] = [blocker for blocker in i.get("blocked_by", []) if status_of.get(blocker, "unknown") != "closed"]
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
# The fields that add up to a session's tokens, per host. Claude's four do not overlap. Codex's
# cached input is part of its input, and its reasoning part of its output.
TOKENS = {"claude": ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"),
          "codex": ("input_tokens", "output_tokens")}
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
        s["tokens"] += sum(u.get(k) for k in TOKENS.get(r.get("host"), ()) if isinstance(u.get(k), int))
if as_json:
    print(json.dumps({"pool": pool, "items": items, "runs": runs, "gates": gates,
                      "overlaps": [list(o) for o in overlap], "spend": spend, "tracker_errors": tracker_errors, "holders": holders}, indent=2)); sys.exit()
def step_of(i):
    step = i["state"].get("step") or "-"
    if step == "split":
        kids = i.get("open_children", 0)
        return "split, waiting on %d child%s" % (kids, "" if kids == 1 else "ren") if kids else "split, every child closed"
    return step
# answer_pending (gate.sh clear): what carries out the owner's answer to a cleared gate, until a
# run takes it. The board says so, so an answer never waits unseen.
OWNERS = {"next": "next", "comments": "the comments job"}
def owner_of(i):
    o = i["state"].get("answer_pending") or ""
    return OWNERS.get(o, o)
def gate_of(i):
    gate = i["state"].get("gate") or "none"
    return "none, answer waits on %s" % owner_of(i) if gate == "none" and owner_of(i) else gate
def worktree_of(item):
    worktree = item["state"].get("worktree") or "-"
    base = claimed_bases.get(item["id"], {}).get("base", "")
    return "%s, base %s" % (worktree, base) if base and base != config_base else worktree
# Who raised the gate, who carries the answer out, and the condition the health job clears it on
# (gate.sh raise). A record written before these fields shows none of them.
ROLES = (("raised_by", "raised by"), ("answered_by", "answered by"), ("condition", "waits on"))
def roles_of(g):
    said = ["%s %s" % (label, g[key]) for key, label in ROLES if g.get(key)]
    return " (%s)" % ", ".join(said) if said else ""
print("## Waiting on you" if gates else "## Waiting on you: nothing")
for gate in gates:
    print("- **%s** on %s (%s): %s%s" % (gate["gate"], gate["item"], gate["time"], str(gate["message"]).splitlines()[0] if gate["message"] != "" else "", roles_of(gate)))
now = time.time()
waiting = [g for g in gates if now - epoch(g["time"]) > reminder]
dead = [r for r in runs if not r["alive"] and not r["starting"]]
# An answer that waited past the gate reminder: no run took it.
unanswered = [i for i in items if (i["state"].get("gate") or "none") == "none" and owner_of(i)
              and epoch(i["state"].get("answered_at")) and now - epoch(i["state"].get("answered_at")) > reminder]
missing_bases = [claimed for claimed in claimed_bases.values() if claimed["missing"]]
if dead or waiting or unanswered or missing_bases:
    print("\n## Health")
    for r in dead:
        print("- %s: dead run of %s, no process since the record was written (%s ago)" % (r["item"], r["step"], age(r["age"])))
    for g in waiting:
        print("- %s: waiting %s at the %s gate" % (g["item"], age(now - epoch(g["time"])), g["gate"]))
    for i in unanswered:
        print("- %s: the answer to its gate has waited %s on %s" % (i["id"], age(now - epoch(i["state"]["answered_at"])), owner_of(i)))
    for claimed in missing_bases:
        print("- %s: base %s is not on the remote" % (claimed["item"], claimed["base"]))
if overlap:
    print("\n## Overlapping claims")
    for a, b in overlap:
        print("- %s and %s touch the same paths" % (a, b))
if tracker_errors:
    print("\n## Trackers not read")
    for tracker_error in tracker_errors:
        print("- %s (exit %s): %s" % (tracker_error["tracker"], tracker_error["code"], tracker_error["message"] or "no reason given"))
def print_table_heading(title, columns, rows, empty_note):
    if not rows:
        print("\n## %s: %s" % (title, empty_note))
        return
    print("\n## %s" % title)
    print("| %s |" % " | ".join(columns))
    print("|" + "---|" * len(columns))
RANK_AFTER_EVERY_RANKED_ITEM = 999
TITLE_WIDTH = 50
print_table_heading("Items", ("item", "kind", "priority", "size", "title", "step", "gate", "worktree", "blocked by"), items, "none open")
for item in sorted(items, key=lambda item: item.get("rank", RANK_AFTER_EVERY_RANKED_ITEM)):
    state = item["state"]
    print("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (item["id"], item["kind"], item.get("priority", ""), item.get("size") or state.get("size", ""), item["title"][:TITLE_WIDTH],
          step_of(item), gate_of(item), worktree_of(item), ", ".join(item["open_blockers"]) or "-"))
print_table_heading("Pool", ("worktree", "branch", "item", "step", "last event", "state"), pool, "no worktrees")
for pool_entry in pool:
    last_event = by_id.get(pool_entry["item"], {}).get("state", {}).get("last_event", "")
    run_note = ""
    if pool_entry["item"] in running:
        run_record = running[pool_entry["item"]]
        run_note = " (running on %s)" % run_record["host"] if run_record["alive"] else " (run starting)" if run_record["starting"] else " (dead run)"
    print("| %s | %s | %s | %s | %s | %s%s |" % (pool_entry["worktree"], pool_entry["branch"], pool_entry["item"] or "-", pool_entry["step"] or "-", last_event, pool_entry["state"], run_note))
if spend:
    print("\n## Spend (unattended step sessions)")
    print("| item | cost | sessions | tokens |")
    print("|---|---|---|---|")
    for item, item_spend in sorted(spend.items(), key=lambda spend_entry: -spend_entry[1]["cost_usd"]):
        print("| %s | $%.2f | %d | %d |" % (item, item_spend["cost_usd"], item_spend["sessions"], item_spend["tokens"]))

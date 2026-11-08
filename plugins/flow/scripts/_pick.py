"""The pick in next.sh: which ready item to try next, or why there is none.

  _pick.py <plugin> <runs dir> <full> <skip>

stdin: line 1 the ready list (a JSON array, best first), line 2 the items filter-ready held back
(a JSON array of its FLOW_READY_NOTES lines; may be absent). <full> is the item whose claim found
the pool full in this pick, empty while none did; <skip> the items this pick passed over,
space-separated.

Prints the first item to try and exits 0. An item with a run in flight is not tried, nor one this
pick passed over. Once the pool is full, neither is one that holds no claim (state.worktree empty)
and whose step needs a worktree: it would cost a tracker read and a claim that cannot succeed.
With nothing left it prints why, one line, and exits 3 when the pool is full, else 5.
"""
import json, os, sys

plugin, runs, full = sys.argv[1], sys.argv[2], sys.argv[3]
skip = set(sys.argv[4].split())
lines = sys.stdin.read().split("\n")
ready = json.loads(lines[0]) if lines[0].strip() else []
notes = json.loads(lines[1]) if len(lines) > 1 and lines[1].strip() else []
with open(os.path.join(plugin, "profiles.json"), encoding="utf-8") as f:
    profiles = json.load(f)


def slug(item_id):
    return item_id.translate(str.maketrans(":/#", "---"))


def running(item_id):
    return os.path.isfile(os.path.join(runs, slug(item_id) + ".json"))


def profile(item):
    """profile_select in lib/flow.sh, from the ready-list entry: the state's profile, else the
    kind's, by size for a task."""
    state = item.get("state", {})
    if state.get("profile"):
        return state["profile"]
    size = state.get("size") or item.get("size") or profiles.get("default_size") or "M"
    select = profiles["select"].get(item.get("kind", ""))
    if isinstance(select, str):
        return select
    return (select or profiles["select"]["task"]).get(size, "")


def needs_worktree(item):
    """Whether the item's next step runs in a pool worktree; an unknown step counts as one."""
    step = item.get("state", {}).get("step") or next(iter(profiles["profiles"].get(profile(item), [])), "")
    return profiles["steps"].get(step, {}).get("worktree", True) is not False


def claimed(item):
    return bool(item.get("state", {}).get("worktree"))


waiting = 0
for item in ready:
    cid = item["id"]
    if running(cid):
        continue
    if full and not claimed(item) and needs_worktree(item):
        if cid not in skip or cid == full:
            waiting += 1
        continue
    if cid in skip:
        continue
    print(cid)
    sys.exit(0)


def count(n, what):
    return f"{n} {what}"


def held_list(rows):
    pairs = [f"{r['id']} behind {r['held_by']}" for r in rows[:5]]
    more = f", and {len(rows) - 5} more" if len(rows) > 5 else ""
    return f"({', '.join(pairs)}{more})"


WHY = [("gate", "at a gate"), ("blocked", "blocked"), ("needs", "missing a field ready.needs asks for"),
       ("children", "waiting on child items"), ("done", "done (every step ran)"), ("split", "split")]


def reasons(rows, live):
    """The parts of the reason: running, held (each named), then the rest by why."""
    parts = []
    if live:
        parts.append(count(live, "running"))
    held = [r for r in rows if r["why"] == "held"]
    if held:
        parts.append(f"{len(held)} held {held_list(held)}")
    for why, said in WHY:
        n = sum(1 for r in rows if r["why"] == why)
        if n:
            parts.append(f"{n} {said}")
    return parts


seen, unique = set(), []
for r in notes:
    if r["id"] not in seen:
        seen.add(r["id"]); unique.append(r)
passed = len(skip - {full})
if full:
    # Why the claimed worktrees do not move: what each claimed item is doing.
    live = sum(1 for i in ready if claimed(i) and running(i["id"]))
    parts = reasons([r for r in unique if r.get("worktree")], live)
    said = f"no free worktree for the {waiting} unclaimed ready item(s), and the pool is at pool_max"
    said += f"; the claimed items: {', '.join(parts)}" if parts else ""
    said += f"; {count(passed, 'passed over (said above)')}" if passed else ""
    print(said)
    sys.exit(3)
live = sum(1 for i in ready if running(i["id"]))
parts = reasons(unique, live) + ([count(passed, "passed over (said above)")] if passed else [])
print("nothing ready: " + (", ".join(parts) if parts else "no open item"))
sys.exit(5)

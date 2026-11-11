"""Ready filter for the adapters. See filter-ready.sh."""
import json, os, subprocess, sys
plugin = sys.argv[1]
items = json.load(sys.stdin)
known = {i["id"]: i.get("status", "open") for i in items}
cache = {}

def read_prefix(name):
    try:
        with open(os.path.join(plugin, "adapters", name, "prefix"), encoding="utf-8") as f:
            return f.readline().strip()
    except OSError:
        return ""

# Each adapter's id prefix, as lib/flow.sh's adapter_for reads it (adapters/README.md).
PREFIXES = [(prefix, name) for name in sorted(os.listdir(os.path.join(plugin, "adapters")))
            for prefix in [read_prefix(name)] if prefix]

def adapter_for(item_id):
    return next((name for prefix, name in PREFIXES if item_id.startswith(prefix)), None)

def status_of(item_id):
    """open, closed, or unknown (no adapter owns the id, or its read failed). An item in the list
    is known without a read; any other is read once through its adapter."""
    if item_id in known:
        return known[item_id]
    if item_id not in cache:
        name = adapter_for(item_id)
        status = "unknown"
        if name:
            try:
                out = subprocess.run([os.path.join(plugin, "adapters", name, "read.sh"), item_id],
                                     capture_output=True, text=True, timeout=60)
                if out.returncode == 0 and out.stdout.strip():
                    status = json.loads(out.stdout).get("status", "open")
            except Exception:
                pass
        cache[item_id] = status
    return cache[item_id]

# A blocker holds unless it reads closed: one that cannot be read may still be open.
def blocker_open(item_id):
    return status_of(item_id) != "closed"

# A holder holds only while it reads open: one closed or not found frees the item, and the health
# job clears the stale hold later.
def holder_open(item_id):
    return status_of(item_id) == "open"

try:
    with open(os.path.join(plugin, "profiles.json"), encoding="utf-8") as f:
        PROFILES = json.load(f).get("profiles", {})
except (OSError, ValueError):
    PROFILES = {}

def hold_applies(state):
    """A hold keeps back only the steps after the plan: the plan and the steps before it still run,
    because a plan sent back is planned again and decides the hold anew. An item with no known
    profile, or a profile with no plan, is held at every step."""
    steps = [s for s in PROFILES.get(state.get("profile", ""), []) if isinstance(s, str)]
    if "plan" not in steps:
        return True
    return state.get("step", "") not in steps[:steps.index("plan") + 1]

def open_blockers(item):
    """The item's open blockers. An adapter that knows its blockers' states lists the open ones (the
    GitHub one does); only without that is each blocker read through its adapter, one call apiece."""
    if "open_blockers" in item:
        return item["open_blockers"]
    return [b for b in item.get("blocked_by", []) if blocker_open(b)]

def held_back(item):
    """Why an open item is not ready, in one word, or None when it is ready."""
    state = item.get("state", {})
    if state.get("gate", "none") not in ("", "none"):
        return "gate"
    if item.get("needs"):
        return "needs"
    if item.get("open_children"):
        return "children"
    if state.get("step") in ("split", "done"):
        return state["step"]
    if open_blockers(item):
        return "blocked"
    if state.get("held_by") and hold_applies(state) and holder_open(state["held_by"]):
        return "held"
    return None

ready, notes = [], []
for item in items:
    if item.get("status", "open") != "open":
        continue
    why = held_back(item)
    if why is None:
        ready.append(item)
        continue
    state = item.get("state", {})
    note = {"id": item["id"], "worktree": state.get("worktree", ""), "why": why}
    if why == "held":
        note.update(held_by=state["held_by"], held_reason=state.get("held_reason", ""))
    elif why == "blocked":
        note.update(blocked_by=open_blockers(item))
    notes.append(note)
ready.sort(key=lambda i: i.get("rank", 999))
print(json.dumps(ready))
# FLOW_READY_NOTES names a file that gets one JSON line per open item held back, with why: next.sh
# reads them to say why a pick found nothing, at no extra tracker call.
if os.environ.get("FLOW_READY_NOTES"):
    with open(os.environ["FLOW_READY_NOTES"], "a", encoding="utf-8") as f:
        for note in notes:
            f.write(json.dumps(note) + "\n")

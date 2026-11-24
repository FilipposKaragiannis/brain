"""Ready filter for the adapters. See filter-ready.sh."""
import functools
import json
import os
import re
import subprocess
import sys
from typing import Callable, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _ready_policy as ready_policy  # noqa: E402

plugin = sys.argv[1]
# The flow home, where gate.sh clear --option writes the blockers the owner waived (lib/blockers.sh).
home = sys.argv[2] if len(sys.argv) > 2 else ""
items = json.load(sys.stdin)
known = {i["id"]: i.get("status", "open") for i in items}
# The gate each open item waits at: a child waits while its parent's split is not approved.
GATE_THAT_HOLDS_CHILDREN = "decomposition"
gates = {i["id"]: i.get("state", {}).get("gate", "none") for i in items if i.get("status", "open") == "open"}
listed = {i["id"]: i for i in items}
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

# How long one adapter read may take before the item counts as unread.
READ_TIMEOUT_SECONDS = 60

def read_item(item_id):
    """An item not in the list, read once with its flow record joined on (state.sh read); empty when
    no adapter owns the id or its read failed."""
    if item_id not in cache:
        name = adapter_for(item_id)
        item = {}
        if name:
            try:
                out = subprocess.run([os.path.join(plugin, "scripts", "state.sh"), "read", item_id],
                                     capture_output=True, text=True, timeout=READ_TIMEOUT_SECONDS)
                if out.returncode == 0 and out.stdout.strip():
                    item = json.loads(out.stdout)
            except Exception:
                pass
        cache[item_id] = item if isinstance(item, dict) else {}
    return cache[item_id]

def status_of(item_id):
    """open, closed, or unknown (no adapter owns the id, or its read failed). An item in the list
    is known without a read; any other is read once through its adapter."""
    if item_id in known:
        return known[item_id]
    item = read_item(item_id)
    return item.get("status", "open") if item else "unknown"

def gate_of(item_id):
    """The gate an open item waits at, else none. An item in the list is known without a read; one
    a filter left out (list-ready --kind or --pick) is read once through its adapter."""
    if item_id in known:
        return gates.get(item_id, "none")
    item = read_item(item_id)
    if item.get("status", "open") != "open":
        return "none"
    return (item.get("state") or {}).get("gate", "none")

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

def waived(item_id):
    """The blockers the owner chose not to wait for on this item: an option picked on a gate that
    waits on blocked_by:<blocker> (gate.sh clear --option), one id per line in the flow home."""
    if not home:
        return set()
    slug = item_id.translate(str.maketrans(":/#", "---"))
    try:
        with open(os.path.join(home, "waived", slug), encoding="utf-8") as f:
            return {line.strip() for line in f if line.strip()}
    except OSError:
        return set()

def open_blockers(item):
    """The item's open blockers the owner did not waive. An adapter that knows its blockers' states
    lists the open ones (the GitHub one does); only without that is each blocker read through its
    adapter, one call apiece."""
    skip = waived(item["id"])
    if "open_blockers" in item:
        return [b for b in item["open_blockers"] if b not in skip]
    return [b for b in item.get("blocked_by", []) if b not in skip and blocker_open(b)]

# The epic walk of lib/base.sh (fetch_item_base), which refuses the claim of an epic's child while
# no epic above it has an epic branch: how far up it reads, the repository whose remote holds the
# epic branches, how long one git call there may take, and the base: line that names another base.
ANCESTOR_LEVELS = 5
GIT_TIMEOUT_SECONDS = 60
EPIC_BRANCHES = "epic/"
BASE_LINE = re.compile(r"^base:[ \t]*[^ \t\n]", re.MULTILINE)
repository = os.path.dirname(home) if home else ""

def git(*arguments):
    """One git call in the flow's repository: its lines when it exits 0, else None."""
    try:
        done = subprocess.run(["git", "-C", repository, *arguments], capture_output=True, text=True,
                              timeout=GIT_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout.split() if done.returncode == 0 else None

@functools.lru_cache(maxsize=None)
def epic_branches(fetched):
    """The epic branches on the remote, as the last fetch saw them or, fetched, as it holds them
    now. In a repository with no origin, the local ones, as base_exists reads them. None when the
    repository cannot be read."""
    has_origin = git("remote", "get-url", "origin") is not None
    if has_origin and fetched:
        git("fetch", "-q", "--no-tags", "origin", f"+refs/heads/{EPIC_BRANCHES}*:refs/remotes/origin/{EPIC_BRANCHES}*")
    refs = "refs/remotes/origin/" if has_origin else "refs/heads/"
    names = git("for-each-ref", "--format=%(refname)", refs + EPIC_BRANCHES)
    return None if names is None else {name[len(refs):] for name in names}

def epic_branch(epic_id):
    """epic_branch in lib/base.sh: the id past its last #, / or :, after epic/."""
    return EPIC_BRANCHES + re.split(r"[#/:]", epic_id)[-1]

def epic_branch_missing(epic_id):
    """Whether the remote holds no epic branch for the epic. A branch the last fetch did not see is
    fetched for once: an item held back here never reaches the claim that would fetch it. A
    repository that cannot be read misses none, so the claim decides."""
    for fetched in (False, True):
        branches = epic_branches(fetched)
        if branches is None or epic_branch(epic_id) in branches:
            return False
    return True

def item_of(item_id):
    return listed.get(item_id) or read_item(item_id)

def holds_claim(item):
    return bool((item.get("state") or {}).get("worktree"))

@functools.lru_cache(maxsize=None)
def pool_claim(item_id):
    """Whether a pool worktree holds a claim of the item, as steward.sh find reads the claim files.
    The state's worktree field misses a claim whose state write failed, and the claim keeps such
    an item its base (claim_at_base in lib/base.sh)."""
    try:
        found = subprocess.run([os.path.join(plugin, "scripts", "steward.sh"), "find", item_id],
                               stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=READ_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return found.returncode == 0 and bool(found.stdout.strip())

def epics_above(item):
    """The epics among the item's ancestors, nearest first, as far as the walk reads."""
    epics, walked, ancestor_id = [], set(), item.get("parent")
    while ancestor_id and ancestor_id not in walked and len(walked) < ANCESTOR_LEVELS:
        ancestor = item_of(ancestor_id)
        if ancestor.get("kind") == "epic":
            epics.append(ancestor_id)
        walked.add(ancestor_id)
        ancestor_id = ancestor.get("parent")
    return epics

def starts_a_claim(item):
    """Whether the item's next step claims a worktree from a base the claim still has to resolve:
    it holds none, it is no epic (an epic's steps run in no worktree), and neither its parent's
    claim nor a base: line in its body gives the base."""
    if not item.get("parent") or holds_claim(item) or item.get("kind") == "epic":
        return False
    body = (item.get("body") or "").replace("`", "").replace("\r", "")
    return not holds_claim(item_of(item["parent"])) and not BASE_LINE.search(body)

def epic_without_branch(item):
    """The nearest epic above an item whose claim waits for an epic branch, else None."""
    if not repository or not starts_a_claim(item):
        return None
    epics = epics_above(item)
    if not epics or not all(epic_branch_missing(epic_id) for epic_id in epics):
        return None
    if pool_claim(item["id"]) or pool_claim(item["parent"]):
        return None
    return epics[0]

def policy_verdict(item: dict, policy: ready_policy.ReadyPolicy,
                   me: ready_policy.MeNames) -> ready_policy.NotReady:
    """Why the ready: policy keeps the item back (lib/ready.sh), with its detail, or READY."""
    me_names = functools.partial(me.read_names, adapter_for(item["id"]))
    return ready_policy.not_ready(ready_policy.readiness_item(item), policy, me_names)

def held_back(item: dict, verdict: ready_policy.NotReady) -> Optional[str]:
    """Why an open item is not ready, in one word, or None when it is ready. The verdict is the
    ready: policy's on the item, whose elsewhere comes before the gate and the rest after it."""
    state = item.get("state", {})
    if verdict.why == ready_policy.ELSEWHERE:
        return verdict.why
    if state.get("gate", "none") not in ("", "none"):
        return "gate"
    if verdict.why:
        return verdict.why
    if item.get("needs") and not state.get("step"):
        return "needs"
    if item.get("open_children"):
        return "children"
    if item.get("parent") and not state.get("step") and gate_of(item["parent"]) == GATE_THAT_HOLDS_CHILDREN:
        return "parent"
    if epic_without_branch(item):
        return "epic-branch"
    if state.get("step") in ("split", "done"):
        return state["step"]
    if open_blockers(item):
        return "blocked"
    if state.get("held_by") and hold_applies(state) and holder_open(state["held_by"]):
        return "held"
    return None

AFTER_EVERY_NUMBERED_ITEM = float("inf")
RANK_WITHOUT_PRIORITY = 999

def number_ending_the_id(item):
    digits = item["id"][len(item["id"].rstrip("0123456789")):]
    return int(digits) if digits else AFTER_EVERY_NUMBERED_ITEM

def note_of(item: dict, why: str, verdict: ready_policy.NotReady) -> dict:
    """The note of an open item held back: its id, worktree and why, with what the why names."""
    state = item.get("state", {})
    note = {"id": item["id"], "worktree": state.get("worktree", ""), "why": why}
    if why == "held":
        note.update(held_by=state["held_by"], held_reason=state.get("held_reason", ""))
    elif why == "blocked":
        note.update(blocked_by=open_blockers(item))
    elif why == "epic-branch":
        epic_id = epic_without_branch(item)
        note.update(epic=epic_id, branch=epic_branch(epic_id))
    elif why in ready_policy.WORDS:
        note.update(verdict.detail)
    return note

def write_notes(notes: list, path: str) -> None:
    with open(path, "a", encoding="utf-8") as notes_file:
        notes_file.writelines(json.dumps(note) + "\n" for note in notes)

def append_line(path: str, message: str) -> None:
    with open(path, "a", encoding="utf-8") as warnings_file:
        warnings_file.write(message + "\n")

def warning_writer(path: str) -> Callable[[str], None]:
    """Where a warning goes: appended to the file FLOW_READY_WARNINGS names, else stderr."""
    if path:
        return functools.partial(append_line, path)
    return functools.partial(print, file=sys.stderr)

def main() -> None:
    policy = ready_policy.policy_from(os.environ)
    me = ready_policy.MeNames(plugin, warning_writer(os.environ.get("FLOW_READY_WARNINGS", "")))
    ready, notes = [], []
    for item in (item for item in items if item.get("status", "open") == "open"):
        verdict = policy_verdict(item, policy, me)
        why = held_back(item, verdict)
        if why is None:
            ready.append(item)
        else:
            notes.append(note_of(item, why, verdict))
    ready.sort(key=lambda ready_item: (ready_item.get("rank", RANK_WITHOUT_PRIORITY),
                                       number_ending_the_id(ready_item)))
    print(json.dumps(ready))
    if os.environ.get("FLOW_READY_NOTES"):
        write_notes(notes, os.environ["FLOW_READY_NOTES"])

if __name__ == "__main__":
    main()

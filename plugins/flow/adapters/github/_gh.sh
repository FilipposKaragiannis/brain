#!/bin/sh
# Shared pieces of the GitHub adapter. Items are issues; ids are gh#<number>. State is mirrored
# as labels (step:*, gate:*, wt:*, flow:*, and size:* unless github.fields.size names a field) and
# kept in full in one issue comment marked <!-- flow:state -->.
. "$(dirname "$0")/../../lib/flow.sh"
# lib/flow.sh wraps gh in a function, so the check looks past it to the command.
(unset -f gh; command -v gh >/dev/null 2>&1) || die "gh is not installed"
STATE_MARKER="<!-- flow:state -->"

gh_repo() {
  r="$(cfg "github.repo")"
  [ -n "$r" ] && { printf '%s' "$r"; return; }
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || die "not a GitHub repository (set github.repo in .flow/config.yaml)"
}

issue_number() {
  case "$1" in gh#*) printf '%s' "${1#gh#}" ;; *) die "not a GitHub item id: $1" 2 ;; esac
}

# assignee_login <assignee>: the login a pick or github.scope names as its assignee, with me read
# as the gh user.
assignee_login() {
  [ "$1" = me ] || { printf '%s' "$1"; return 0; }
  _login="$(gh api user -q .login)" && [ -n "$_login" ] \
    || die "cannot read the gh user that assignee: me stands for; log in with gh auth login"
  printf '%s' "$_login"
}

# The opt-in GitHub features, from .flow/config.yaml: github.fields.size and github.fields.priority
# name org issue fields (each replaces its size: or priority: labels), github.project numbers the
# project whose Status the adapter keeps in step and reads an item's category from, through the
# Status names github.status.<key> renames. The readiness rules are every tracker's (ready_rules in
# lib/flow.sh); list and read take them before they build items.
GH_SIZE_FIELD="$(cfg github.fields.size)"; GH_PRIORITY_FIELD="$(cfg github.fields.priority)"; GH_AREA_FIELD="$(cfg github.fields.area)"
GH_PROJECT="$(cfg github.project)"; GH_PRIORITY_LABEL="priority:"
GH_STATUS_BACKLOG="$(cfg_or github.status.backlog Backlog)"; GH_STATUS_READY="$(cfg_or github.status.ready Ready)"
GH_STATUS_GATE="$(cfg_or github.status.gate "Needs you")"; GH_STATUS_RUNNING="$(cfg_or github.status.running "In progress")"
GH_STATUS_REVIEW="$(cfg_or github.status.review "In review")"
export GH_SIZE_FIELD GH_PRIORITY_FIELD GH_AREA_FIELD GH_PROJECT GH_PRIORITY_LABEL \
  GH_STATUS_BACKLOG GH_STATUS_READY GH_STATUS_GATE GH_STATUS_RUNNING GH_STATUS_REVIEW

# project_sync [item JSON lines on stdin]: move the project cards to the Status the flow state
# implies. A no-op without github.project.
project_sync() {
  [ -n "$GH_PROJECT" ] || { cat >/dev/null; return 0; }
  cached_python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" sync "$(gh_repo)" "$GH_PROJECT"
}

# issue_to_item: stdin one raw issue from _query.py; stdout the adapter item JSON. Kind: as
# _query.py's kind_of reads it, the issue type Epic or Bug, else the label epic or bug, else task.
# Parent: the native sub-issue parent, else a "Parent #N" line in the body. Priority: the
# github.fields.priority field when set, else the priority: label, the one earliest in
# READY_PRIORITY_ORDER when there are two; priority_labels lists the priority: labels that decided
# it, empty with the field set. rank orders ready items (lower first) by READY_PRIORITY_ORDER;
# needs lists the READY_NEEDS fields an unstarted item still lacks, the same rule as the local
# adapter's _item.py (change both); open_children counts its open native sub-issues. assignees are
# the logins as GitHub gives them. category: done when closed, unknown with no github.project card
# or a card with no Status, else the card's Status read back through the GH_STATUS_* names, and
# blocked for a Status outside them.
issue_to_item() {
  cached_python3 -I -c '
import json, os, re, sys
text = sys.stdin.read()
if not text.strip():
    sys.exit(1)  # the read before this failed and said why
raw = json.loads(text)
labels = [l["name"] for l in raw.get("labels", [])]
fields = raw.get("fields") or {}
state = dict(raw.get("state_comment") or {})
def labelled(prefix, default):
    for l in labels:
        if l.startswith(prefix):
            return l[len(prefix):]
    return default
state.setdefault("attempts", 0); state.setdefault("last_event", ""); state.setdefault("pr", ""); state.setdefault("touches", []); state.setdefault("changes", []); state.setdefault("held_by", ""); state.setdefault("held_reason", "")
state["step"] = labelled("step:", state.get("step", ""))
state["gate"] = labelled("gate:", state.get("gate", "none")) or "none"
state["worktree"] = labelled("wt:", state.get("worktree", ""))
state["profile"] = labelled("flow:", state.get("profile", ""))
size_field, priority_field = os.environ.get("GH_SIZE_FIELD", ""), os.environ.get("GH_PRIORITY_FIELD", "")
size = (fields.get(size_field) or "") if size_field else ""
size = size or labelled("size:", state.get("size", ""))
state["size"] = size
order = [priority_name for priority_name in os.environ.get("READY_PRIORITY_ORDER", "").split(",") if priority_name]
order_places = {priority_name: order.index(priority_name) for priority_name in order}
def read_priority(labels, fields, priority_field, priority_place, prefix):
    if priority_field:
        return fields.get(priority_field) or "", []
    priority_labels = [label for label in labels if label.startswith(prefix)]
    labelled_priorities = sorted((label[len(prefix):] for label in priority_labels), key=priority_place)
    return (labelled_priorities or [""])[0], priority_labels
priority, priority_labels = read_priority(labels, fields, priority_field, lambda name: order_places.get(name, len(order)), os.environ["GH_PRIORITY_LABEL"])
area_field = os.environ.get("GH_AREA_FIELD", "")
area = (fields.get(area_field) or "") if area_field else ""
NO_RANK = 999
rank = NO_RANK if not priority else order_places.get(priority, len(order))
m = re.search(r"(?im)^Parent:? #(\d+)", raw.get("body", "") or "")
parent = "gh#%d" % raw["parent"]["number"] if raw.get("parent") else "gh#%s" % m.group(1) if m else ""
kind = raw.get("kind") or "task"
is_open = raw.get("state", "OPEN").upper() == "OPEN"
needs = []
if is_open and not state["step"]:
    for need in [n for n in os.environ.get("READY_NEEDS", "").split(",") if n]:
        if need == "priority" and not priority: needs.append(need)
        if need == "size" and not size and kind != "epic": needs.append(need)
project = os.environ.get("GH_PROJECT", "")
item = next((p for p in raw.get("project_items", []) if project and str(p["project"]) == project), None)
STATUS_CATEGORIES = {os.environ["GH_STATUS_BACKLOG"]: "todo", os.environ["GH_STATUS_READY"]: "todo",
                     os.environ["GH_STATUS_RUNNING"]: "in-progress", os.environ["GH_STATUS_REVIEW"]: "review",
                     os.environ["GH_STATUS_GATE"]: "blocked"}
def category_of(is_open: bool, card: dict) -> str:
    if not is_open:
        return "done"
    if not card.get("status"):
        return "unknown"
    return STATUS_CATEGORIES.get(card["status"], "blocked")
print(json.dumps({
    "id": "gh#%d" % raw["number"], "kind": kind, "type": raw.get("type") or "", "title": raw.get("title", ""), "size": size,
    "priority": priority, "priority_labels": priority_labels, "area": area, "rank": rank, "needs": needs,
    "status": "open" if is_open else "closed", "category": category_of(is_open, item or {}), "assignees": raw.get("assignees", []),
    "labels": labels, "blocked_by": ["gh#%d" % b["number"] for b in raw.get("blocked_by", [])],
    "open_blockers": ["gh#%d" % b["number"] for b in raw.get("blocked_by", []) if b.get("state", "open") != "closed"],
    "open_children": raw.get("open_children", 0), "parent": parent, "state": state, "url": raw.get("url", ""), "body": raw.get("body", ""),
    "project": {"item": item["id"], "status": item["status"]} if item else {},
}))'
}

# state_comment <repo> <number>: the JSON inside the flow state comment, or {}, with the
# comment's id. A failed read returns 1, and the caller must stop: taken for "no comment yet",
# it would make write-state start a second state comment from an empty state, dropping the
# attempts, the PR and the touches.
state_comment() {
  comments="$(gh api --paginate --slurp "repos/$1/issues/$2/comments?per_page=100")" || return 1
  printf '%s' "$comments" | cached_python3 -I -c '
import json, sys, re
marker = sys.argv[1]
for c in [c for page in json.load(sys.stdin) for c in page]:
    body = c.get("body", "")
    if marker in body:
        m = re.search(r"```json\n(.*?)\n```", body, re.S)
        try:
            data = json.loads(m.group(1)) if m else {}
        except ValueError:
            data = {}
        print(json.dumps({"id": c["id"], "data": data})); break
else:
    print(json.dumps({"id": None, "data": {}}))' "$STATE_MARKER"
}

# ensure_label <label>: create it when missing (gh issue edit fails on unknown labels).
ensure_label() {
  case "$1" in
    step:*) color="1D76DB" ;; gate:*) color="D93F0B" ;; wt:*) color="0E8A16" ;; flow:*) color="5319E7" ;; size:*) color="FBCA04" ;; "$GH_PRIORITY_LABEL"*) color="B60205" ;; *) color="EDEDED" ;;
  esac
  gh label create "$1" --color "$color" --description "flow state" --force >/dev/null 2>&1 || true
}

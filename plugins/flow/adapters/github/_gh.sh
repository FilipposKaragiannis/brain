#!/bin/sh
# Shared pieces of the GitHub adapter. Items are issues; ids are gh#<number>. State is mirrored
# as labels (step:*, gate:*, wt:*, flow:*, and size:* unless github.fields.size names a field) and
# kept in full in one issue comment marked <!-- flow:state -->.
. "$(dirname "$0")/../../lib/flow.sh"
command -v gh >/dev/null 2>&1 || die "gh is not installed"
STATE_MARKER="<!-- flow:state -->"

gh_repo() {
  r="$(cfg "github.repo")"
  [ -n "$r" ] && { printf '%s' "$r"; return; }
  gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || die "not a GitHub repository (set github.repo in .flow/config.yaml)"
}

issue_number() {
  case "$1" in gh#*) printf '%s' "${1#gh#}" ;; *) die "not a GitHub item id: $1" 2 ;; esac
}

# The opt-in GitHub features, from .flow/config.yaml: github.fields.size and github.fields.priority
# name org issue fields (the size field replaces the size: labels), github.priority_order ranks the
# priority options, github.ready_needs lists the fields an unstarted item needs before it is ready,
# github.project numbers the project whose Status the adapter keeps in step.
GH_SIZE_FIELD="$(cfg github.fields.size)"; GH_PRIORITY_FIELD="$(cfg github.fields.priority)"; GH_AREA_FIELD="$(cfg github.fields.area)"
GH_PRIORITY_ORDER="$(cfg github.priority_order | paste -sd, -)"; GH_READY_NEEDS="$(cfg github.ready_needs | paste -sd, -)"
GH_PROJECT="$(cfg github.project)"
export GH_SIZE_FIELD GH_PRIORITY_FIELD GH_AREA_FIELD GH_PRIORITY_ORDER GH_READY_NEEDS GH_PROJECT
for _need in $(printf '%s' "$GH_READY_NEEDS" | tr , ' '); do
  case "$_need" in priority|size) ;; *) echo "flow: github.ready_needs knows priority and size, not $_need" >&2 ;; esac
done
for _key in backlog ready gate running review; do
  _v="$(cfg "github.status.$_key")"
  [ -n "$_v" ] && export "GH_STATUS_$(printf '%s' "$_key" | tr a-z A-Z)=$_v"
done

# project_sync [item JSON lines on stdin]: move the project cards to the Status the flow state
# implies. A no-op without github.project.
project_sync() {
  [ -n "$GH_PROJECT" ] || { cat >/dev/null; return 0; }
  python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" sync "$(gh_repo)" "$GH_PROJECT"
}

# issue_to_item: stdin one raw issue from _query.py; stdout the adapter item JSON. Kind: the issue
# type Epic or Bug, else the label epic or bug, else task. Parent: the native sub-issue parent,
# else a "Parent #N" line in the body. rank orders ready items (lower first); needs lists the
# github.ready_needs fields an unstarted item still lacks; open_children counts its open native
# sub-issues.
issue_to_item() {
  python3 -I -c '
import json, os, re, sys
raw = json.load(sys.stdin)
labels = [l["name"] for l in raw.get("labels", [])]
fields = raw.get("fields") or {}
state = dict(raw.get("state_comment") or {})
def labelled(prefix, default):
    for l in labels:
        if l.startswith(prefix):
            return l[len(prefix):]
    return default
state.setdefault("attempts", 0); state.setdefault("last_event", ""); state.setdefault("pr", ""); state.setdefault("touches", [])
state["step"] = labelled("step:", state.get("step", ""))
state["gate"] = labelled("gate:", state.get("gate", "none")) or "none"
state["worktree"] = labelled("wt:", state.get("worktree", ""))
state["profile"] = labelled("flow:", state.get("profile", ""))
size_field, priority_field = os.environ.get("GH_SIZE_FIELD", ""), os.environ.get("GH_PRIORITY_FIELD", "")
size = (fields.get(size_field) or "") if size_field else ""
size = size or labelled("size:", state.get("size", ""))
state["size"] = size
priority = (fields.get(priority_field) or "") if priority_field else ""
area_field = os.environ.get("GH_AREA_FIELD", "")
area = (fields.get(area_field) or "") if area_field else ""
order = [p for p in os.environ.get("GH_PRIORITY_ORDER", "").split(",") if p]
rank = 999 if not priority else order.index(priority) if priority in order else len(order)
m = re.search(r"(?im)^Parent:? #(\d+)", raw.get("body", "") or "")
parent = "gh#%d" % raw["parent"]["number"] if raw.get("parent") else "gh#%s" % m.group(1) if m else ""
kind = {"Epic": "epic", "Bug": "bug"}.get(raw.get("type") or "", "")
if not kind and raw.get("type"): kind = "task"
if not kind: kind = "epic" if "epic" in labels or "kind:epic" in labels else "bug" if "bug" in labels or "kind:bug" in labels else labelled("kind:", "task")
is_open = raw.get("state", "OPEN").upper() == "OPEN"
needs = []
if is_open and not state["step"]:
    for need in [n for n in os.environ.get("GH_READY_NEEDS", "").split(",") if n]:
        if need == "priority" and not priority: needs.append(need)
        if need == "size" and not size and kind != "epic": needs.append(need)
project = os.environ.get("GH_PROJECT", "")
item = next((p for p in raw.get("project_items", []) if project and str(p["project"]) == project), None)
print(json.dumps({
    "id": "gh#%d" % raw["number"], "kind": kind, "type": raw.get("type") or "", "title": raw.get("title", ""), "size": size,
    "priority": priority, "area": area, "rank": rank, "needs": needs,
    "status": "open" if is_open else "closed",
    "labels": labels, "blocked_by": ["gh#%d" % b["number"] for b in raw.get("blocked_by", [])],
    "open_blockers": ["gh#%d" % b["number"] for b in raw.get("blocked_by", []) if b.get("state", "open") != "closed"],
    "open_children": raw.get("open_children", 0), "parent": parent, "state": state, "url": raw.get("url", ""), "body": raw.get("body", ""),
    "project": {"item": item["id"], "status": item["status"]} if item else {},
}))'
}

# state_comment <repo> <number>: the JSON inside the flow state comment, or {}; sets STATE_COMMENT_ID.
state_comment() {
  comments="$(gh api "repos/$1/issues/$2/comments?per_page=100" 2>/dev/null || echo '[]')"
  printf '%s' "$comments" | python3 -I -c '
import json, sys, re
marker = sys.argv[1]
for c in json.load(sys.stdin):
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
    step:*) color="1D76DB" ;; gate:*) color="D93F0B" ;; wt:*) color="0E8A16" ;; flow:*) color="5319E7" ;; size:*) color="FBCA04" ;; *) color="EDEDED" ;;
  esac
  gh label create "$1" --color "$color" --description "flow state" --force >/dev/null 2>&1 || true
}

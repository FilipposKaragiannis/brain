#!/bin/sh
# Shared pieces of the GitHub adapter. Items are issues; ids are gh#<number>. State is mirrored
# as labels (step:*, gate:*, wt:*, flow:*, size:*) and kept in full in one issue comment marked
# <!-- flow:state -->. Kind: label epic -> epic, bug -> bug, else task.
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

# issue_to_item: stdin one `gh issue view --json ...` object plus `blocked_by` and `state_comment`
# fields merged in; stdout the adapter item JSON.
issue_to_item() {
  python3 -I -c '
import json, re, sys
raw = json.load(sys.stdin)
labels = [l["name"] for l in raw.get("labels", [])]
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
size = labelled("size:", state.get("size", ""))
state["size"] = size
m = re.search(r"(?im)^Parent #(\d+)", raw.get("body", "") or "")
parent = "gh#%s" % m.group(1) if m else ("gh#%d" % raw["parent"]["number"] if raw.get("parent") else "")
kind = "epic" if "epic" in labels or "kind:epic" in labels else "bug" if "bug" in labels or "kind:bug" in labels else labelled("kind:", "task")
print(json.dumps({
    "id": "gh#%d" % raw["number"], "kind": kind, "title": raw.get("title", ""), "size": size,
    "status": "open" if raw.get("state", "OPEN").upper() == "OPEN" else "closed",
    "labels": labels, "blocked_by": ["gh#%d" % b["number"] for b in raw.get("blocked_by", [])],
    "parent": parent, "state": state, "url": raw.get("url", ""), "body": raw.get("body", ""),
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

blocked_by() { gh api "repos/$1/issues/$2/dependencies/blocked_by" 2>/dev/null || echo '[]'; }

# ensure_label <label>: create it when missing (gh issue edit fails on unknown labels).
ensure_label() {
  case "$1" in
    step:*) color="1D76DB" ;; gate:*) color="D93F0B" ;; wt:*) color="0E8A16" ;; flow:*) color="5319E7" ;; size:*) color="FBCA04" ;; *) color="EDEDED" ;;
  esac
  gh label create "$1" --color "$color" --description "flow state" --force >/dev/null 2>&1 || true
}

# parent_of <repo> <number>: the sub-issue parent as JSON {number} or null (GraphQL).
parent_of() {
  owner="${1%%/*}"; name="${1#*/}"
  gh api graphql -f query="{ repository(owner:\"$owner\", name:\"$name\") { issue(number:$2) { parent { number } } } }" -q '.data.repository.issue.parent' 2>/dev/null || echo null
}

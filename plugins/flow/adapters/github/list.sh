#!/bin/sh
# github list [--all] [--kind KIND] [--limit N] [--pick NAME]: open issues (all with --all) as
# adapter items. One paged GraphQL query; the state comment is read only for issues that carry a
# flow label. Stops at github.limit (default 500) and says so. With FLOW_LIST_WHOLE set, a cut list
# fails. github.scope bounds every list (scope_filter in lib/flow.sh), and --pick keeps the issues
# the filter pick.<name> matches inside it (pick_filter): the assignee's login (me is the gh user),
# labels, state and kind, or its query as search qualifiers. A scope goes to GitHub as search
# qualifiers (_query.py), and its kinds and the pick's fields are matched before github.limit
# counts an issue, so the limit counts the issues they keep.
. "$(dirname "$0")/_gh.sh"
ready_rules
scope_filter github
pick_filter github "$@" || { echo '[]'; exit 0; }
FLOW_SCOPE_ASSIGNEE="$(assignee_login "$FLOW_SCOPE_ASSIGNEE")" || exit
FLOW_PICK_ASSIGNEE="$(assignee_login "$FLOW_PICK_ASSIGNEE")" || exit
state="open"; kind=""; limit="$(cfg_or github.limit 500)"
while [ $# -gt 0 ]; do
  case "$1" in
    --all) state="all"; shift ;;
    --kind) kind="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    --pick) shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac
done
repo="$(gh_repo)"
raw="$(python3 -I "$FLOW_PLUGIN/adapters/github/_query.py" list "$repo" "$STATE_MARKER" "$state" "$limit")" || die "cannot list issues"
printf '%s\n' "$raw" | while read -r line; do [ -n "$line" ] && printf '%s\n' "$line" | issue_to_item; done | python3 -I -c '
import json, sys
kind = sys.argv[1]
items = [json.loads(line) for line in sys.stdin if line.strip()]
print(json.dumps([item for item in items if not kind or item["kind"] == kind]))' "$kind"

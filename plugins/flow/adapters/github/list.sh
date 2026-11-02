#!/bin/sh
# github list [--all] [--kind KIND] [--limit N] [--pick NAME]: open issues (all with --all) as
# adapter items. One paged GraphQL query; the state comment is read only for issues that carry a
# flow label. Stops at github.limit (default 500) and says so. With FLOW_LIST_WHOLE set, a cut list
# fails. --pick keeps the issues the filter pick.<name> matches (pick_filter in lib/flow.sh): the
# assignee's login (me is the gh user), labels, state and kind, or its query as search qualifiers.
. "$(dirname "$0")/_gh.sh"
ready_rules
pick_filter github "$@" || { echo '[]'; exit 0; }
if [ "$FLOW_PICK_ASSIGNEE" = me ]; then
  FLOW_PICK_ASSIGNEE="$(gh api user -q .login)" && [ -n "$FLOW_PICK_ASSIGNEE" ] \
    || die "cannot read the gh user that assignee: me stands for; log in with gh auth login"
fi
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
import json, os, sys
kind = sys.argv[1]
kinds = {k.strip().lower() for k in os.environ.get("FLOW_PICK_KINDS", "").split(",") if k.strip()}
items = [json.loads(line) for line in sys.stdin if line.strip()]
print(json.dumps([i for i in items if (not kind or i["kind"] == kind) and (not kinds or i["kind"] in kinds)]))' "$kind"

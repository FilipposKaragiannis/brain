#!/bin/sh
# github list [--all] [--kind KIND] [--limit N]: open issues (all with --all) as adapter items.
# One paged GraphQL query; the state comment is read only for issues that carry a flow label.
# Stops at github.limit (default 500) and says so.
. "$(dirname "$0")/_gh.sh"
state="open"; kind=""; limit="$(cfg_or github.limit 500)"
while [ $# -gt 0 ]; do
  case "$1" in
    --all) state="all"; shift ;;
    --kind) kind="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac
done
repo="$(gh_repo)"
raw="$(python3 -I "$FLOW_PLUGIN/adapters/github/_query.py" list "$repo" "$STATE_MARKER" "$state" "$limit")" || die "cannot list issues"
printf '%s\n' "$raw" | while read -r line; do [ -n "$line" ] && printf '%s\n' "$line" | issue_to_item; done | python3 -I -c 'import json,sys; k=sys.argv[1]; print(json.dumps([i for i in (json.loads(l) for l in sys.stdin if l.strip()) if not k or i["kind"]==k]))' "$kind"

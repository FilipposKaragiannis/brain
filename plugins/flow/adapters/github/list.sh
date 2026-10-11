#!/bin/sh
# github list [--all] [--kind KIND] [--limit N]: open issues (all with --all) as adapter items.
# Blockers come from the dependencies API, one call per issue; the state comment is read only
# for issues that carry a flow label, to keep the call count low.
. "$(dirname "$0")/_gh.sh"
state="open"; kind=""; limit="$(cfg_or github.limit 100)"
while [ $# -gt 0 ]; do
  case "$1" in
    --all) state="all"; shift ;;
    --kind) kind="$2"; shift 2 ;;
    --limit) limit="$2"; shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac
done
repo="$(gh_repo)"
issues="$(gh issue list -R "$repo" --state "$state" --limit "$limit" --json number,title,body,state,labels,url)" || die "cannot list issues"
printf '%s' "$issues" | python3 -I "$FLOW_PLUGIN/adapters/github/_list.py" "$repo" "$kind" "$STATE_MARKER" | while read -r line; do printf '%s\n' "$line" | issue_to_item; done | python3 -I -c 'import json,sys; k=sys.argv[1]; print(json.dumps([i for i in (json.loads(l) for l in sys.stdin if l.strip()) if not k or i["kind"]==k]))' "$kind"

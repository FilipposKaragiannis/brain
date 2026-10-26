#!/bin/sh
# github create <kind> <title> [--size S|M|L] [--type NAME] [--area NAME] [--priority NAME] [--blocked-by gh#a,gh#b] [--body TEXT] [--parent gh#N]:
# a new issue; prints its id. With github.types true the kind sets the issue type (epic Epic, bug
# Bug, task Task, or --type), else epic adds the epic label and bug the bug label. The size goes to
# the github.fields.size issue field when set, else a size: label; the area to github.fields.area
# when set, else nowhere (the body names it); the priority to github.fields.priority when set,
# else nowhere, said on stderr. A parent makes it a native
# sub-issue; blockers become native dependency edges (and stay readable in the body).
. "$(dirname "$0")/_gh.sh"
[ $# -ge 2 ] || die "usage: create <kind> <title> [--size S] [--blocked-by a,b] [--body TEXT] [--parent gh#N]" 2
kind="$1"; title="$2"; shift 2
size=""; blocked=""; body=""; parent=""; type=""; area=""; priority=""
while [ $# -gt 0 ]; do
  case "$1" in
    --size) size="$2"; shift 2 ;;
    --type) type="$2"; shift 2 ;;
    --area) area="$2"; shift 2 ;;
    --priority) priority="$2"; shift 2 ;;
    --blocked-by) blocked="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --parent) parent="$2"; shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac
done
repo="$(gh_repo)"
labels=""; types="$(cfg github.types)"
if [ "$types" = "true" ]; then
  [ -n "$type" ] || case "$kind" in epic) type="Epic" ;; bug) type="Bug" ;; *) type="Task" ;; esac
else
  case "$kind" in epic) labels="epic" ;; bug) labels="bug" ;; esac
fi
[ -n "$size" ] && [ -z "$GH_SIZE_FIELD" ] && { ensure_label "size:$size"; labels="${labels:+$labels,}size:$size"; }
tail=""
[ -n "$parent" ] && tail="$tail
Parent #$(issue_number "$parent")"
[ -n "$blocked" ] && tail="$tail
Blocked by $(printf '%s\n' "$blocked" | tr ',' '\n' | while read -r b; do [ -n "$b" ] && printf '#%s ' "$(issue_number "$b")"; done)"
[ -n "$labels" ] && set -- --label "$labels" || set --
url="$(printf '%s\n%s\n' "$body" "$tail" | gh_once issue create -R "$repo" --title "$title" --body-file - "$@")" || die "cannot create the issue"
n="${url##*/}"
[ -n "$type" ] && { python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" type "$repo" "$n" "$type" || echo "flow: could not set gh#$n to type $type" >&2; }
[ -n "$size" ] && [ -n "$GH_SIZE_FIELD" ] && { python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" field "$repo" "$n" "$GH_SIZE_FIELD" "$size" || echo "flow: could not set the size of gh#$n" >&2; }
area_field="$GH_AREA_FIELD"
if [ -n "$priority" ]; then
  if [ -n "$GH_PRIORITY_FIELD" ]; then python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" field "$repo" "$n" "$GH_PRIORITY_FIELD" "$priority" || echo "flow: could not set the priority of gh#$n" >&2
  else echo "flow: github.fields.priority is not set, so gh#$n has no priority $priority" >&2; fi
fi
[ -n "$area" ] && [ -n "$area_field" ] && { python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" field "$repo" "$n" "$area_field" "$area" || echo "flow: could not set the area of gh#$n" >&2; }
if [ -n "$parent" ]; then
  pid="$(gh issue view "$(issue_number "$parent")" -R "$repo" --json id -q .id)"
  cid="$(gh issue view "$n" -R "$repo" --json id -q .id)"
  gh api graphql -f query='mutation($p:ID!,$c:ID!){addSubIssue(input:{issueId:$p,subIssueId:$c}){issue{number}}}' -f p="$pid" -f c="$cid" >/dev/null || echo "flow: could not link gh#$n under $parent" >&2
fi
if [ -n "$blocked" ]; then
  printf '%s\n' "$blocked" | tr ',' '\n' | while read -r b; do
    [ -n "$b" ] || continue
    bid="$(gh api "repos/$repo/issues/$(issue_number "$b")" --jq .id)"
    gh api --method POST "repos/$repo/issues/$n/dependencies/blocked_by" -F issue_id="$bid" >/dev/null || echo "flow: could not record gh#$n blocked by $b" >&2
  done
fi
printf 'gh#%s\n' "$n"

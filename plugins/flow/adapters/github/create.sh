#!/bin/sh
# github create <kind> <title> [--size S|M|L] [--blocked-by gh#a,gh#b] [--body TEXT] [--parent gh#N]:
# a new issue; prints its id. kind epic adds the epic label, bug the bug label. A parent makes it
# a native sub-issue; blockers become native dependency edges (and stay readable in the body).
. "$(dirname "$0")/_gh.sh"
[ $# -ge 2 ] || die "usage: create <kind> <title> [--size S] [--blocked-by a,b] [--body TEXT] [--parent gh#N]" 2
kind="$1"; title="$2"; shift 2
size=""; blocked=""; body=""; parent=""
while [ $# -gt 0 ]; do
  case "$1" in
    --size) size="$2"; shift 2 ;;
    --blocked-by) blocked="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --parent) parent="$2"; shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac
done
repo="$(gh_repo)"
labels=""
case "$kind" in epic) labels="epic" ;; bug) labels="bug" ;; esac
[ -n "$size" ] && { ensure_label "size:$size"; labels="${labels:+$labels,}size:$size"; }
tail=""
[ -n "$parent" ] && tail="$tail
Parent #$(issue_number "$parent")"
[ -n "$blocked" ] && tail="$tail
Blocked by $(printf '%s\n' "$blocked" | tr ',' '\n' | while read -r b; do [ -n "$b" ] && printf '#%s ' "$(issue_number "$b")"; done)"
[ -n "$labels" ] && set -- --label "$labels" || set --
url="$(printf '%s\n%s\n' "$body" "$tail" | gh issue create -R "$repo" --title "$title" --body-file - "$@")" || die "cannot create the issue"
n="${url##*/}"
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

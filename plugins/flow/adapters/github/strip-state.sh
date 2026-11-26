#!/bin/sh
# github strip-state <id>: take the flow's state off the issue. Temporary: state.sh import --strip
# is its one caller, and it goes when write-state goes. It removes the step:, gate:, wt: and flow:
# labels and every comment that starts with <!-- flow:state --> and that a login trusted_logins
# names wrote, and leaves the size: and priority: labels, the size field and every other comment,
# such as a reply that quotes the marker or a marker comment by anyone else: the flow deletes only
# what it wrote. A label with a comma in it is left and said, as gh would read it as two. Prints
# the id when it removed something, nothing when the issue was clean. Exit 2 for an id that is not
# GitHub's, 1 when GitHub fails or cannot say whose comments count.
set -u
. "$(dirname "$0")/_gh.sh"
[ $# -eq 1 ] || die "usage: strip-state <id>" "$EXIT_USAGE"
item="$1"
number="$(issue_number "$item")" || exit "$EXIT_USAGE"
repository="$(gh_repo)" || exit 1
labels="$(gh issue view "$number" -R "$repository" --json labels -q '.labels[].name')" || die "cannot read the labels of $item"
comments="$(gh api --paginate --slurp "repos/$repository/issues/$number/comments?per_page=$GH_REST_PAGE_SIZE")" || die "cannot read the comments of $item"
state_authors="$(trusted_logins)" || die "cannot tell whose state comments count on $item (set github.answer_from, or log in with gh auth login)"
state_comment_ids="$(printf '%s' "$comments" | cached_python3 -I "$FLOW_PLUGIN/adapters/github/_state_comment.py" ids "$STATE_MARKER" "$state_authors")" \
  || die "cannot read the comments of $item"
set --
removed_labels=0
while IFS= read -r label; do
  case "$label" in step:*|gate:*|wt:*|flow:*) ;; *) continue ;; esac
  case "$label" in *,*) echo "flow: left the label '$label' on $item: a comma in it would make gh remove two" >&2; continue ;; esac
  set -- "$@" --remove-label "$label"
  removed_labels=$((removed_labels + 1))
done <<LABELS
$labels
LABELS
if [ "$removed_labels" -gt 0 ]; then
  gh issue edit "$number" -R "$repository" "$@" >/dev/null || die "cannot take the flow labels off $item"
fi
deleted_comments=0
while IFS= read -r comment_id; do
  [ -n "$comment_id" ] || continue
  gh api -X DELETE "repos/$repository/issues/comments/$comment_id" >/dev/null || die "cannot delete the state comment of $item"
  deleted_comments=$((deleted_comments + 1))
done <<COMMENTS
$state_comment_ids
COMMENTS
[ $((removed_labels + deleted_comments)) -eq 0 ] || printf '%s\n' "$item"

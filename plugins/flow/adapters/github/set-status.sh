#!/bin/sh
# github set-status <id> <backlog|ready|in-progress|needs-you|in-review>: move the issue's card on
# github.project to the Status github.status.<key> names (running for in-progress, gate for
# needs-you, review for in-review), adding the card when the issue has none, and print
# "<id> <Status>". Without a project, github.claim_label is put on the issue for in-progress and
# taken off for any other status, printing "<id> <label>" or "<id> <status>"; with neither, nothing
# is called. Prints nothing when the issue is there already. Exit 2 for another name or a foreign
# id, 1 when GitHub fails or the project has no such Status.
set -u
. "$(dirname "$0")/_gh.sh"
usage="usage: set-status <id> <backlog|ready|in-progress|needs-you|in-review>"
[ $# -eq 2 ] || die "$usage" "$EXIT_USAGE"
item="$1"; status="$2"
case "$status" in
  backlog) native_status="$GH_STATUS_BACKLOG" ;;
  ready) native_status="$GH_STATUS_READY" ;;
  in-progress) native_status="$GH_STATUS_RUNNING" ;;
  needs-you) native_status="$GH_STATUS_GATE" ;;
  in-review) native_status="$GH_STATUS_REVIEW" ;;
  *) die "set-status takes backlog, ready, in-progress, needs-you or in-review, not $status" "$EXIT_USAGE" ;;
esac
number="$(issue_number "$item")" || exit "$EXIT_USAGE"
if [ -n "$GH_PROJECT" ]; then
  item_json="$("$FLOW_PLUGIN/adapters/github/read.sh" "$item")" || exit 1
  printf '%s' "$item_json" | cached_python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" status "$(gh_repo)" "$GH_PROJECT" "$native_status"
  exit
fi
[ -n "$GH_CLAIM_LABEL" ] || exit 0
repo="$(gh_repo)"
labels="$(gh issue view "$number" -R "$repo" --json labels -q '.labels[].name')" || die "cannot read the labels of $item"
if printf '%s\n' "$labels" | grep -qxF -- "$GH_CLAIM_LABEL"; then
  [ "$status" != in-progress ] || exit 0
  gh issue edit "$number" -R "$repo" --remove-label "$GH_CLAIM_LABEL" >/dev/null || die "cannot take the label $GH_CLAIM_LABEL off $item"
  printf '%s %s\n' "$item" "$status"
elif [ "$status" = in-progress ]; then
  ensure_label "$GH_CLAIM_LABEL"
  gh issue edit "$number" -R "$repo" --add-label "$GH_CLAIM_LABEL" >/dev/null || die "cannot put the label $GH_CLAIM_LABEL on $item"
  printf '%s %s\n' "$item" "$GH_CLAIM_LABEL"
fi

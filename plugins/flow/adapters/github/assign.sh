#!/bin/sh
# github assign <id> <me|none>: add the gh login `me` prints to the issue's assignees, or take it
# off, leaving any other assignee. Prints "<id> <login>" when it changed the issue, nothing when the
# issue already said so. Exit 2 for another target or a foreign id, 1 when GitHub fails.
set -u
. "$(dirname "$0")/_gh.sh"
[ $# -eq 2 ] || die "usage: assign <id> <me|none>" "$EXIT_USAGE"
item="$1"; target="$2"
case "$target" in
  me) assignee_flag=--add-assignee ;;
  none) assignee_flag=--remove-assignee ;;
  *) die "assign takes me or none, not $target" "$EXIT_USAGE" ;;
esac
number="$(issue_number "$item")" || exit "$EXIT_USAGE"
repo="$(gh_repo)"
login="$("$FLOW_PLUGIN/adapters/github/me.sh" | head -n 1)"
[ -n "$login" ] || exit 1
assignees="$(gh issue view "$number" -R "$repo" --json assignees -q '.assignees[].login')" || die "cannot read the assignees of $item"
if printf '%s\n' "$assignees" | grep -qxiF -- "$login"; then
  [ "$target" = none ] || exit 0
else
  [ "$target" = me ] || exit 0
fi
gh issue edit "$number" -R "$repo" "$assignee_flag" "$login" >/dev/null || die "cannot change the assignees of $item"
printf '%s %s\n' "$item" "$login"

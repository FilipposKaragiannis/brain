#!/bin/sh
# jira answers: clear each gate the owner answered on the issue. An answer is a comment after the
# latest "**Gate: <gate>**" comment whose first word is /answer, by the user the API token belongs
# to or an account id or email in jira.answer_from; the rest of the comment is the answer
# ("/answer" alone means as recommended). The merge gate is left alone: it clears when the PR is
# merged. gate.sh comments "Gate cleared: ..." on the issue, the owner's receipt, since Jira's REST
# API has no reactions. The item's id prints once it is cleared.
. "$(dirname "$0")/_jira.sh"
[ $# -eq 0 ] || die "usage: answers" 2
found="$(jira answers)" || exit 1
printf '%s\n' "$found" | while read -r line; do
  [ -n "$line" ] || continue
  id="$(json_get "$line" id)"; text="$(json_get "$line" text)"
  "$FLOW_PLUGIN/scripts/gate.sh" clear "$id" "$text" >/dev/null || { echo "flow: could not clear the gate on $id" >&2; continue; }
  echo "$id"
done

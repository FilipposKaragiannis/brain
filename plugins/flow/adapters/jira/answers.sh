#!/bin/sh
# jira answers <id>...: clear each gate the owner answered on the issue, for the ids given (the
# job passes the gated items of the flow records). An answer is a comment after the latest
# "**Gate: <gate>**" comment whose first word is /answer, by the user the API token belongs to or
# an account id or email in jira.answer_from; the rest of the comment is the answer ("/answer"
# alone means as recommended). An id whose record holds no gate, or the merge gate (it clears
# when the PR is merged), or whose issue is outside jira.scope (scope_filter in lib/flow.sh), is
# left alone. gate.sh comments "Gate cleared: ..." on the issue, the owner's receipt, since Jira's
# REST API has no reactions. The item's id prints once it is cleared. No ids prints nothing; an id
# that is not a Jira item's exits 2.
[ $# -gt 0 ] || exit 0
. "$(dirname "$0")/_jira.sh"
. "$FLOW_PLUGIN/lib/answers.sh"
answer_items_required jira "$@"
gated_items="$(answerable_gates "$@")"
[ -n "$gated_items" ] || exit 0
scope_filter jira
# shellcheck disable=SC2086 # the ids are item_id_shaped, so no id holds a space or a glob
found="$(jira answers $gated_items)" || exit 1
printf '%s\n' "$found" | while read -r line; do
  [ -n "$line" ] || continue
  id="$(json_get "$line" id)"; text="$(json_get "$line" text)"
  "$FLOW_PLUGIN/scripts/gate.sh" clear "$id" "$text" >/dev/null || { echo "flow: could not clear the gate on $id" >&2; continue; }
  echo "$id"
done

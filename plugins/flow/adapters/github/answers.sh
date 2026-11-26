#!/bin/sh
# github answers <id>...: clear each gate the owner answered on the issue, for the ids given (the
# job passes the gated items of the flow records). An answer is a comment after the latest
# "**Gate: <gate>**" comment whose first word is /answer, by the authenticated user or a login in
# github.answer_from; the rest of the comment is the answer ("/answer" alone means as
# recommended). An id whose record holds no gate, or the merge gate (it clears when the PR is
# merged), or whose issue is outside github.scope (read through the scoped list), is left alone.
# Each answered comment gets a +1 reaction, and the item's id prints once it is cleared. No ids
# prints nothing; an id that is not a GitHub item's exits 2.
[ $# -gt 0 ] || exit 0
. "$(dirname "$0")/_gh.sh"
. "$FLOW_PLUGIN/lib/answers.sh"
answer_items_required github "$@"
gated_items="$(record_list gates 2>/dev/null | answerable_gates github "$@")"
if [ -n "$gated_items" ] && scope_in_config; then
  gated_items="$("$FLOW_PLUGIN/adapters/github/list.sh" </dev/null | cached_python3 -I -c '
import json, sys
listed = {item["id"] for item in json.load(sys.stdin)}
print("\n".join(gated for gated in sys.argv[1].splitlines() if gated in listed))' "$gated_items")" || exit 1
fi
[ -n "$gated_items" ] || exit 0
repo="$(gh_repo)"
allowed="$(trusted_logins)" || die "cannot tell whose answers count: set github.answer_from"
while read -r gated_item <&3; do
  found="$(gh api "repos/$repo/issues/$(issue_number "$gated_item")/comments?per_page=100" 2>/dev/null | cached_python3 -I -c '
import json, sys
allowed = set(sys.argv[1].split(","))
comments = json.load(sys.stdin)
last = max([k for k, c in enumerate(comments) if (c.get("body") or "").startswith("**Gate: ")], default=-1)
if last < 0: sys.exit()
for c in comments[last + 1:]:
    body = (c.get("body") or "").strip()
    if body.split(None, 1)[:1] == ["/answer"] and (c.get("user") or {}).get("login") in allowed:
        text = body[len("/answer"):].strip() or "as recommended"
        print(json.dumps({"id": c["id"], "text": text})); break' "$allowed")"
  [ -n "$found" ] || continue
  answer_text="$(json_get "$found" text)"; comment_id="$(json_get "$found" id)"
  "$FLOW_PLUGIN/scripts/gate.sh" clear "$gated_item" "$answer_text" >/dev/null || { echo "flow: could not clear the gate on $gated_item" >&2; continue; }
  gh api -X POST "repos/$repo/issues/comments/$comment_id/reactions" -f content=+1 >/dev/null 2>&1 || true
  echo "$gated_item"
done 3<<GATED
$gated_items
GATED

#!/bin/sh
# github answers: clear each gate the owner answered on the issue. An answer is a comment after
# the latest "**Gate: <gate>**" comment whose first word is /answer, by the authenticated user or
# a login in github.answer_from; the rest of the comment is the answer ("/answer" alone means as
# recommended). The merge gate is left alone: it clears when the PR is merged. Each answered
# comment gets a +1 reaction, and the item's id prints once it is cleared.
. "$(dirname "$0")/_gh.sh"
repo="$(gh_repo)"
allowed="$(cfg github.answer_from | paste -sd, -)"
[ -n "$allowed" ] || allowed="$(gh api user -q .login 2>/dev/null)"
[ -n "$allowed" ] || die "cannot tell whose answers count: set github.answer_from"
"$FLOW_PLUGIN/adapters/github/list.sh" | python3 -I -c '
import json, sys
for i in json.load(sys.stdin):
    gate = (i.get("state") or {}).get("gate") or "none"
    if gate not in ("none", "merge"): print(i["id"][3:])' | while read -r n; do
  found="$(gh api "repos/$repo/issues/$n/comments?per_page=100" 2>/dev/null | python3 -I -c '
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
  text="$(json_get "$found" text)"; cid="$(json_get "$found" id)"
  "$FLOW_PLUGIN/scripts/gate.sh" clear "gh#$n" "$text" >/dev/null || { echo "flow: could not clear the gate on gh#$n" >&2; continue; }
  gh api -X POST "repos/$repo/issues/comments/$cid/reactions" -f content=+1 >/dev/null 2>&1 || true
  echo "gh#$n"
done

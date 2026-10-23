#!/bin/sh
# PR comment plumbing for the comments step (GitHub only).
#   comments.sh threads <pr>                    unresolved review threads as JSON
#   comments.sh reply <pr> <comment_id> <text>  reply in a review thread
#   comments.sh resolve <thread_id>             resolve a review thread
#   comments.sh issue-comments <pr>             plain PR comments as JSON (quiz answers live here)
#   comments.sh ready <pr>                      mark a draft PR ready for review
#   comments.sh state <pr>                      {state, isDraft, mergedAt, url, headRefName, headRefOid, baseRefName, mergeable}
#   comments.sh reviewers                       the reviewers each round asks, one per line (reviews.reviewers)
#   comments.sh request-review <pr> <ask>       ask each reviewer: a comment "@<reviewer> <ask>" each, copilot through the API
#   comments.sh reviews <pr>                    each reviewer's last request: answered, waiting, chases (JSON lines)
#   comments.sh chase <pr>                      ask again a reviewer silent past reviews.chase_after, at most
#                                               reviews.max_chases times per request, then tell the owner once
. "$(dirname "$0")/../lib/flow.sh"
command -v gh >/dev/null 2>&1 || die "gh is not installed"
repo="$(cfg github.repo)"; [ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || die "not a GitHub repository"
owner="${repo%%/*}"; name="${repo#*/}"
pr_number() { printf '%s' "$1" | sed 's|.*/||; s/^#//'; }
reviewers() {
  list="$(cfg reviews.reviewers)"; [ -n "$list" ] || list="codex
claude"
  printf '%s\n' "$list" | sed 's/^@//' | while read -r r; do
    case "$r" in ""|*[!A-Za-z0-9_.-]*) die "reviews.reviewers: '$r' is not a reviewer name (codex, claude, copilot or a GitHub login)" 2 ;; esac
    echo "$r"
  done
}
case "${1:-}" in
  threads)
    n="$(pr_number "$2")"
    gh api graphql -f query="{ repository(owner:\"$owner\", name:\"$name\") { pullRequest(number:$n) { reviewThreads(first:100) { nodes { id isResolved isOutdated path line comments(first:50) { nodes { databaseId body author { login } createdAt } } } } } } }" \
      | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
out = []
for t in d:
    if t["isResolved"]: continue
    cs = t["comments"]["nodes"]
    if not cs: continue
    out.append({"thread_id": t["id"], "path": t["path"], "line": t["line"], "outdated": t["isOutdated"],
                "comment_id": cs[0]["databaseId"], "author": (cs[0]["author"] or {}).get("login", ""), "body": cs[0]["body"],
                "replies": [{"author": (c["author"] or {}).get("login", ""), "body": c["body"]} for c in cs[1:]]})
print(json.dumps(out, indent=2))' ;;
  reply)
    n="$(pr_number "$2")"
    printf '%s' "$4" | gh api --method POST "repos/$repo/pulls/$n/comments/$3/replies" -F body=@- >/dev/null ;;
  resolve)
    gh api graphql -f query='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{isResolved}}}' -f t="$2" >/dev/null ;;
  issue-comments)
    n="$(pr_number "$2")"
    gh api "repos/$repo/issues/$n/comments?per_page=100" | python3 -I -c '
import json, sys
print(json.dumps([{"id": c["id"], "author": c["user"]["login"], "body": c["body"], "created": c["created_at"]} for c in json.load(sys.stdin)], indent=2))' ;;
  ready)
    gh pr ready "$(pr_number "$2")" -R "$repo" ;;
  state)
    gh pr view "$(pr_number "$2")" -R "$repo" --json state,isDraft,mergedAt,url,headRefName,headRefOid,baseRefName,number,mergeable ;;
  reviewers)
    reviewers ;;
  request-review)
    [ $# -ge 3 ] || die "usage: comments.sh request-review <pr> <ask>" 2
    n="$(pr_number "$2")"; list="$(reviewers)" || exit 2
    for r in $list; do
      if [ "$r" = "copilot" ]; then
        gh pr edit "$n" -R "$repo" --add-reviewer @copilot >/dev/null
      else
        printf '@%s %s\n\n<!-- flow:review-request %s -->\n' "$r" "$3" "$r" | gh pr comment "$n" -R "$repo" --body-file - >/dev/null
      fi
      echo "asked $r"
    done ;;
  reviews)
    n="$(pr_number "$2")"; tmp="$(mktemp -d)"; list="$(reviewers)" || exit 2
    gh api "repos/$repo/issues/$n/comments?per_page=100" > "$tmp/comments.json" &&
      gh api "repos/$repo/pulls/$n/reviews?per_page=100" > "$tmp/reviews.json" &&
      gh api "repos/$repo/issues/$n/timeline?per_page=100" > "$tmp/timeline.json" &&
      me="$(gh api user -q .login)" &&
      head="$(gh pr view "$n" -R "$repo" --json headRefOid -q .headRefOid)" &&
      python3 -I "$FLOW_PLUGIN/scripts/_reviews.py" status "$tmp/comments.json" "$tmp/reviews.json" "$tmp/timeline.json" "$me" "$head" "$(date +%s)" $list
    rc=$?; rm -rf "$tmp"; exit $rc ;;
  chase)
    n="$(pr_number "$2")"
    after="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds reviews.chase_after "$(cfg reviews.chase_after | sed 's/^$/1h/')")" || exit 2
    max="$(cfg reviews.max_chases)"; max="${max:-2}"
    head="$(gh pr view "$n" -R "$repo" --json headRefOid -q .headRefOid)"
    home="$(flow_home)"; mkdir -p "$home/reviews"
    "$0" reviews "$n" | while IFS= read -r row; do
      r="$(json_get "$row" reviewer)"; id="$(json_get "$row" asked_id)"; chases="$(json_get "$row" chases)"
      [ "$(json_get "$row" answered)" != "true" ] && [ "$(json_get "$row" waiting)" -ge "$after" ] || continue
      ago="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" ago "$(( $(date +%s) - $(json_get "$row" waiting) ))")"
      if [ "$chases" -lt "$max" ] && [ "$r" = "copilot" ]; then
        gh pr edit "$n" -R "$repo" --add-reviewer @copilot >/dev/null
        echo "chased $r on #$n: no review after $ago, asked again (chase $((chases + 1)) of $max)"
      elif [ "$chases" -lt "$max" ]; then
        printf '@%s review\n\nThe review asked %s ago has no answer yet. Please review %s again: the diff line by line for correctness, and against the acceptance lines of the item.\n\n<!-- flow:chase %s -->\n' \
          "$r" "$ago" "$(printf '%s' "$head" | cut -c1-8)" "$r" | gh pr comment "$n" -R "$repo" --body-file - >/dev/null
        echo "chased $r on #$n: no answer after $ago (chase $((chases + 1)) of $max)"
      elif [ "$(cat "$home/reviews/$n-$r" 2>/dev/null)" != "$id" ]; then
        echo "$id" > "$home/reviews/$n-$r"
        "$FLOW_PLUGIN/scripts/notify.sh" --event review-stalled "PR #$n: $r has not answered the review asked $ago ago, after $max chases. Check $r on the PR, then ask it again by hand or merge without it." >/dev/null
        echo "stalled $r on #$n: no answer after $max chases, the owner is told"
      fi
    done ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac

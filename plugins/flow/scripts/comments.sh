#!/bin/sh
# PR comment plumbing for the comments step (GitHub only).
#   comments.sh threads <pr>                    unresolved review threads as JSON
#   comments.sh reply <pr> <comment_id> <text>  reply in a review thread
#   comments.sh resolve <thread_id>             resolve a review thread
#   comments.sh issue-comments <pr>             plain PR comments as JSON (quiz answers live here)
#   comments.sh ready <pr>                      mark a draft PR ready for review
#   comments.sh state <pr>                      {state, isDraft, merged, url, headRefName, baseRefName}
. "$(dirname "$0")/../lib/flow.sh"
command -v gh >/dev/null 2>&1 || die "gh is not installed"
repo="$(cfg github.repo)"; [ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || die "not a GitHub repository"
owner="${repo%%/*}"; name="${repo#*/}"
pr_number() { printf '%s' "$1" | sed 's|.*/||; s/^#//'; }
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
    gh pr view "$(pr_number "$2")" -R "$repo" --json state,isDraft,mergedAt,url,headRefName,baseRefName,number ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac

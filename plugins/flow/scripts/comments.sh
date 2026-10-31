#!/bin/sh
# PR comment plumbing for the comments step (GitHub only).
#   comments.sh threads <pr>                    unresolved review threads as JSON
#   comments.sh reply <pr> <comment_id> <text>  reply in a review thread, marked as the flow's (REPLY_MARKER)
#   comments.sh resolve <thread_id>             resolve a review thread
#   comments.sh issue-comments <pr>             plain PR comments as JSON (quiz answers live here)
#   comments.sh ready <pr>                      mark a draft PR ready for review
#   comments.sh state <pr>                      {state, isDraft, mergedAt, url, headRefName, headRefOid, baseRefName, mergeable, updatedAt,
#                                               reviewDecision, latestReviews, reviewRequests}
#   comments.sh activity <pr>                   what the comments job compares between passes: updatedAt, headRefOid,
#                                               mergeable, unresolved threads, their comments, and awaiting: the
#                                               last comment ids of the unresolved threads whose last comment does
#                                               not carry the reply marker (in a thread with no marker at all, a
#                                               last reply by the flow's login is ours: replies before 1.19.0)
#   comments.sh reviewers                       the reviewers each round asks, one per line (reviews.reviewers)
#   comments.sh request-review <pr> <ask>       ask each reviewer: a comment "@<reviewer> <ask>" each, copilot through the API
#   comments.sh reviews <pr>                    each reviewer's last request: answered, waiting, chases (JSON lines)
#   comments.sh chase <pr>                      ask again a reviewer silent past reviews.chase_after, at most
#                                               reviews.max_chases times per request, then tell the owner once
. "$(dirname "$0")/../lib/flow.sh"
(unset -f gh; command -v gh >/dev/null 2>&1) || die "gh is not installed"
repo="$(cfg github.repo)"; [ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || die "not a GitHub repository"
owner="${repo%%/*}"; name="${repo#*/}"
# Every reply the flow posts carries this marker, so a thread whose last word is ours is told from
# one the owner answered under the same login.
REPLY_MARKER="<!-- flow:reply -->"
pr_number() { printf '%s' "$1" | sed 's|.*/||; s/^#//'; }
PAGE_SIZE=100          # REST entries per page; --paginate fetches the rest
SHORT_SHA=8            # characters of the head commit a chase names
DEFAULT_CHASE_AFTER=1h # reviews.chase_after when unset
DEFAULT_MAX_CHASES=2   # reviews.max_chases when unset
reviewers() {
  list="$(cfg reviews.reviewers)"; [ -n "$list" ] || list="codex
claude"
  printf '%s\n' "$list" | sed 's/^@//' | while read -r reviewer; do
    case "$reviewer" in ""|*[!A-Za-z0-9_.-]*) die "reviews.reviewers: '$reviewer' is not a reviewer name (codex, claude, copilot or a GitHub login)" 2 ;; esac
    echo "$reviewer"
  done
}
# The ask goes to bots verbatim: no markers that would count as a request or a chase, no extra mentions.
plain_ask() { printf '%s' "$1" | sed 's/<!--//g; s/-->//g; s/@\([A-Za-z0-9]\)/\1/g'; }
ask_reviewer() { # ask_reviewer <pr> <reviewer> <ask>
  if [ "$2" = "copilot" ]; then
    gh pr edit "$1" -R "$repo" --add-reviewer @copilot >/dev/null
  else
    # Once: a ping whose answer was lost after it landed would start a second review; the chase covers a lost one.
    printf '@%s %s\n\n<!-- flow:review-request %s -->\n' "$2" "$(plain_ask "$3")" "$2" | gh_once pr comment "$1" -R "$repo" --body-file - >/dev/null
  fi
}
# Re-adding a Copilot request that is still pending may leave no timeline event, so each chase
# of a round is also counted here: "<round> <chases> <epoch of the last chase>".
copilot_count() { printf '%s/reviews/%s-copilot.chases' "$home" "$1"; }
copilot_seen() { # copilot_seen <pr> <round> <chases> <waiting>: the larger chase count and the shorter wait
  [ -f "$(copilot_count "$1")" ] && read -r counted_round counted last < "$(copilot_count "$1")" && [ "$counted_round" = "$2" ] ||
    { echo "$3 $4"; return; }
  [ "$counted" -gt "$3" ] || counted="$3"
  since_chase=$(( $(date +%s) - last )); [ "$since_chase" -lt "$4" ] || since_chase="$4"
  echo "$counted $since_chase"
}
chase_copilot() { # chase_copilot <pr> <round> <chase number>
  gh pr edit "$1" -R "$repo" --add-reviewer @copilot >/dev/null || return 1
  printf '%s %s %s\n' "$2" "$3" "$(date +%s)" > "$(copilot_count "$1")"
}
chase_mention() { # chase_mention <pr> <reviewer> <ago> <head sha>
  printf '@%s review\n\nThe review asked %s ago has no answer yet. Please review %s again: the diff line by line for correctness, and against the acceptance lines of the item.\n\n<!-- flow:chase %s -->\n' \
    "$2" "$3" "$(printf '%s' "$4" | cut -c1-$SHORT_SHA)" "$2" | gh_once pr comment "$1" -R "$repo" --body-file - >/dev/null
}
report_stalled() { # report_stalled <pr> <reviewer> <request id> <ago> <max>: once per request
  marker="$home/reviews/$1-$2"
  [ "$(cat "$marker" 2>/dev/null)" != "$3" ] || return 0
  "$FLOW_PLUGIN/scripts/notify.sh" --event review-stalled "PR #$1: $2 has not answered the review asked $4 ago, after $5 chases. Check $2 on the PR, then ask it again by hand or merge without it." >/dev/null || return 1
  echo "$3" > "$marker"
  echo "stalled $2 on #$1: no answer after $5 chases, the owner is told"
}
chase_row() { # chase_row <pr> <row> <after s> <max> <head sha>: act on one reviewer's last request
  reviewer="$(json_get "$2" reviewer)"; chases="$(json_get "$2" chases)"; waiting="$(json_get "$2" waiting)"
  [ "$(json_get "$2" answered)" != "true" ] || return 0
  if [ "$reviewer" = "copilot" ]; then
    round="$(json_get "$2" round)"
    seen="$(copilot_seen "$1" "$round" "$chases" "$waiting")"; chases="${seen% *}"; waiting="${seen#* }"
  fi
  [ "$waiting" -ge "$3" ] || return 0
  ago="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" ago "$(( $(date +%s) - $(json_get "$2" waiting) ))")"
  if [ "$chases" -ge "$4" ]; then
    report_stalled "$1" "$reviewer" "$(json_get "$2" asked_id)" "$ago" "$4"
  elif [ "$reviewer" = "copilot" ]; then
    chase_copilot "$1" "$round" "$((chases + 1))" && echo "chased copilot on #$1: no review after $ago, asked again (chase $((chases + 1)) of $4)"
  else
    chase_mention "$1" "$reviewer" "$ago" "$5" && echo "chased $reviewer on #$1: no answer after $ago (chase $((chases + 1)) of $4)"
  fi
}
chase_pr() { # chase_pr <pr>
  # An unset key prints nothing, not an empty line, so the default is a fallback, not a sed.
  after="$(cfg reviews.chase_after)"
  after="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds reviews.chase_after "${after:-$DEFAULT_CHASE_AFTER}")" || exit 2
  max="$(cfg reviews.max_chases)"; max="${max:-$DEFAULT_MAX_CHASES}"
  head="$(gh pr view "$1" -R "$repo" --json headRefOid -q .headRefOid)" || exit 1
  home="$(flow_home)"; mkdir -p "$home/reviews"
  "$0" reviews "$1" | while IFS= read -r row; do chase_row "$1" "$row" "$after" "$max" "$head"; done
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
                "replies": [{"id": c["databaseId"], "author": (c["author"] or {}).get("login", ""), "body": c["body"]} for c in cs[1:]]})
print(json.dumps(out, indent=2))' ;;
  reply)
    n="$(pr_number "$2")"
    printf '%s\n\n%s\n' "$4" "$REPLY_MARKER" | gh api --method POST "repos/$repo/pulls/$n/comments/$3/replies" -F body=@- >/dev/null ;;
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
    gh pr view "$(pr_number "$2")" -R "$repo" --json state,isDraft,mergedAt,url,headRefName,headRefOid,baseRefName,number,mergeable,updatedAt,reviewDecision,latestReviews,reviewRequests ;;
  reviewers)
    reviewers ;;
  request-review)
    [ $# -ge 3 ] || die "usage: comments.sh request-review <pr> <ask>" 2
    pull="$(pr_number "$2")"; list="$(reviewers)" || exit 2
    for reviewer in $list; do
      ask_reviewer "$pull" "$reviewer" "$3" || die "could not ask $reviewer on #$pull"
      echo "asked $reviewer"
    done ;;
  reviews)
    pull="$(pr_number "$2")"; scratch="$(mktemp -d)"; list="$(reviewers)" || exit 2
    gh api --paginate --slurp "repos/$repo/issues/$pull/comments?per_page=$PAGE_SIZE" > "$scratch/comments.json" &&
      gh api --paginate --slurp "repos/$repo/pulls/$pull/reviews?per_page=$PAGE_SIZE" > "$scratch/reviews.json" &&
      gh api --paginate --slurp "repos/$repo/issues/$pull/timeline?per_page=$PAGE_SIZE" > "$scratch/timeline.json" &&
      me="$(gh api user -q .login)" &&
      head="$(gh pr view "$pull" -R "$repo" --json headRefOid -q .headRefOid)" &&
      python3 -I "$FLOW_PLUGIN/scripts/_reviews.py" status "$scratch/comments.json" "$scratch/reviews.json" "$scratch/timeline.json" "$me" "$head" "$(date +%s)" $list
    status=$?; rm -rf "$scratch"; exit $status ;;
  chase)
    chase_pr "$(pr_number "$2")" ;;
  activity)
    pull="$(pr_number "$2")"
    st="$(gh pr view "$pull" -R "$repo" --json updatedAt,headRefOid,mergeable)" &&
      th="$("$0" threads "$pull")" || exit 1
    # A thread with no marker anywhere may hold a reply from before 1.19.0: there the flow's login
    # speaks for it. Read once, only then, through the job's per-run cache when it gives one.
    me=""
    if printf '%s' "$th" | python3 -I -c '
import json, sys
marker = sys.argv[1]
sys.exit(0 if any(marker not in "".join([t["body"] or ""] + [r["body"] or "" for r in t["replies"]]) for t in json.load(sys.stdin)) else 1)' "$REPLY_MARKER"; then
      cache="${FLOW_GH_LOGIN_CACHE:-}"
      if [ -n "$cache" ] && [ -f "$cache" ]; then me="$(cat "$cache")"
      else me="$(gh api user -q .login 2>/dev/null)" || me=""; [ -z "$cache" ] || printf '%s' "$me" > "$cache"; fi
    fi
    python3 -I -c '
import json, sys
state, threads, marker, me = json.loads(sys.argv[1]), json.loads(sys.argv[2]), sys.argv[3], sys.argv[4]
def last(t):
    return t["replies"][-1] if t["replies"] else {"id": t["comment_id"], "body": t["body"], "author": t["author"]}
def ours(t):
    if marker in (last(t)["body"] or ""):
        return True
    marked = any(marker in (c["body"] or "") for c in [t] + t["replies"])
    return bool(t["replies"]) and not marked and bool(me) and last(t).get("author") == me
waiting = [last(t)["id"] for t in threads if not ours(t)]
print(json.dumps({"updatedAt": state.get("updatedAt", ""), "headRefOid": state.get("headRefOid", ""),
                  "mergeable": state.get("mergeable", ""), "unresolved": len(threads),
                  "review_comments": sum(1 + len(t["replies"]) for t in threads),
                  "awaiting": waiting}))' "$st" "$th" "$REPLY_MARKER" "$me" ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac

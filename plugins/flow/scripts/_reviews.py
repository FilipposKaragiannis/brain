"""Review requests on a PR, read side. See scripts/comments.sh reviewers, request-review and chase.

  _reviews.py status <comments.json> <reviews.json> <timeline.json> <me> <head sha> <now epoch> <reviewer>...

comments.json is the PR's issue comments (the REST shape: id, user, body, created_at, updated_at,
reactions), reviews.json its reviews (user, submitted_at), timeline.json its issue timeline. Each
may be one list or the list of pages that gh api --paginate --slurp prints. Prints one JSON object
per reviewer that was asked: the reviewer, the id and time of the last request, whether it is
answered, how long it has waited and how many chases followed the first request still unanswered.

A request is a comment by <me> that opens with @<reviewer> or carries the request marker. A chase
is a request with the chase marker. The reviewer answers with a review or a comment after the last
request, a +1 on the request (Codex's "no findings"), or a finished Codex summary for the head
commit. A Codex summary still running, or a usage-limit reply, is no answer. codex, claude and
copilot are GitHub apps: only a bot account whose login names them speaks for them. Copilot is
asked through the reviewers API, so its requests are the timeline's review_requested events; a
review by it after the last one answers, and every request after the first unanswered one is a
chase. Its round names that first request, so a chase the timeline does not record can be counted
by the caller."""
import calendar, json, re, sys, time

CHASE = "<!-- flow:chase %s -->"
REQUEST = "<!-- flow:review-request %s -->"
SUMMARY = "codex-pull-request-review-summary"
STATE = re.compile(r"codex-review-state:v1 (\{.*?\}) -->")
NOT_AN_ANSWER = re.compile(r"usage limit|rate limit", re.I)
APPS = ("codex", "claude", "copilot")


def epoch(text):
    return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ")) if text else 0


def load(path):
    pages = json.load(open(path))
    return [entry for page in pages for entry in page] if pages and isinstance(pages[0], list) else pages


def authored_by(user, reviewer):
    login = ((user or {}).get("login") or "").lower()
    if reviewer not in APPS:
        return login == reviewer.lower()
    return reviewer in login and (user or {}).get("type") == "Bot"


def is_request(comment, me, reviewer):
    body = comment.get("body") or ""
    return (comment["user"]["login"] == me
            and (body.lower().startswith("@" + reviewer.lower()) or REQUEST % reviewer in body or CHASE % reviewer in body))


def summary_done(comment, head, since):
    match = STATE.search(comment.get("body") or "")
    if not match:
        return False
    review = json.loads(match.group(1)).get("code_review") or {}
    return (review.get("status") not in (None, "", "running") and review.get("commit_sha") == head
            and epoch(comment.get("updated_at")) >= since)


def comment_answers(comment, head, since):
    body = comment.get("body") or ""
    if SUMMARY in body:
        return summary_done(comment, head, since)
    return epoch(comment["created_at"]) >= since and not NOT_AN_ANSWER.search(body)


def reviewed_since(pull, reviewer, since):
    return any(authored_by(review["user"], reviewer) and epoch(review.get("submitted_at")) >= since
               for review in pull["reviews"])


def answered(pull, reviewer, request):
    since = epoch(request["created_at"])
    if (request.get("reactions") or {}).get("+1", 0) > 0 or reviewed_since(pull, reviewer, since):
        return True
    return any(comment_answers(comment, pull["head"], since)
               for comment in pull["comments"] if authored_by(comment["user"], reviewer))


def copilot(pull):
    requests = [event for event in pull["timeline"] if event.get("event") == "review_requested"
                and authored_by(event.get("requested_reviewer"), "copilot")]
    if not requests:
        return None
    last = requests[-1]
    reviewed = max([epoch(review.get("submitted_at")) for review in pull["reviews"]
                    if authored_by(review["user"], "copilot")] or [0])
    unanswered = [event for event in requests if epoch(event["created_at"]) > reviewed]
    return {"reviewer": "copilot", "asked_id": "copilot-%d" % epoch(last["created_at"]), "asked": last["created_at"],
            "answered": not unanswered, "waiting": pull["now"] - epoch(last["created_at"]),
            "chases": max(0, len(unanswered) - 1),
            "round": "copilot-%d" % epoch((unanswered or [last])[0]["created_at"])}


def mentioned(pull, reviewer):
    requests = [comment for comment in pull["comments"] if is_request(comment, pull["me"], reviewer)]
    if not requests:
        return None
    last, chases = requests[-1], 0
    for request in reversed(requests):
        if CHASE % reviewer not in (request.get("body") or ""):
            break
        chases += 1
    return {"reviewer": reviewer, "asked_id": last["id"], "asked": last["created_at"],
            "answered": answered(pull, reviewer, last), "waiting": pull["now"] - epoch(last["created_at"]),
            "chases": chases}


def status(pull, reviewers):
    for reviewer in reviewers:
        row = copilot(pull) if reviewer == "copilot" else mentioned(pull, reviewer)
        if row:
            print(json.dumps(row))


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command != "status":
        sys.exit("flow: unknown command %s" % command)
    comments, reviews, timeline, me, head, now = args[:6]
    pull = {"comments": load(comments), "reviews": load(reviews), "timeline": load(timeline),
            "me": me, "head": head, "now": int(now)}
    status(pull, args[6:])


main()

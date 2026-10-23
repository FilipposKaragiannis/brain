"""Review requests on a PR, read side. See scripts/comments.sh reviewers, request-review and chase.

  _reviews.py status <comments.json> <reviews.json> <timeline.json> <me> <head sha> <now epoch> <reviewer>...

comments.json is the PR's issue comments (the REST shape: id, user.login, body, created_at,
updated_at, reactions), reviews.json its reviews (user.login, submitted_at), timeline.json its
issue timeline. Prints one JSON object per reviewer that was asked: the reviewer, the id and time of
the last request, whether it is answered, how long it has waited and how many chases followed the
first request still unanswered.

A request is a comment by <me> that opens with @<reviewer> or carries the request marker. A chase
is a request with the chase marker. The reviewer answers with a review or a comment after the last
request, a +1 on the request (Codex's "no findings"), or a finished Codex summary for the head
commit. A Codex summary still running, or a usage-limit reply, is no answer. Copilot is asked
through the reviewers API, so its requests are the timeline's review_requested events; a review
by it after the last one answers, and every request after the first unanswered one is a chase."""
import calendar, json, re, sys, time

CHASE = "<!-- flow:chase %s -->"
REQUEST = "<!-- flow:review-request %s -->"
SUMMARY = "codex-pull-request-review-summary"
STATE = re.compile(r"codex-review-state:v1 (\{.*?\}) -->")
NOT_AN_ANSWER = re.compile(r"usage limit|rate limit", re.I)


def epoch(text):
    return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ")) if text else 0


def authored_by(login, reviewer):
    login = (login or "").lower()
    return reviewer.lower() in login if reviewer in ("codex", "claude", "copilot") else login == reviewer.lower()


def is_request(comment, me, reviewer):
    body = comment.get("body") or ""
    return (comment["user"]["login"] == me
            and (body.lower().startswith("@" + reviewer.lower()) or REQUEST % reviewer in body or CHASE % reviewer in body))


def summary_done(comment, head, since):
    m = STATE.search(comment.get("body") or "")
    if not m:
        return False
    review = json.loads(m.group(1)).get("code_review") or {}
    return (review.get("status") not in (None, "", "running") and review.get("commit_sha") == head
            and epoch(comment.get("updated_at")) >= since)


def answered(reviewer, request, comments, reviews, head):
    since = epoch(request["created_at"])
    if (request.get("reactions") or {}).get("+1", 0) > 0:
        return True
    for r in reviews:
        if authored_by(r["user"]["login"], reviewer) and epoch(r.get("submitted_at")) >= since:
            return True
    for c in comments:
        if not authored_by(c["user"]["login"], reviewer):
            continue
        body = c.get("body") or ""
        if SUMMARY in body:
            if summary_done(c, head, since):
                return True
        elif epoch(c["created_at"]) >= since and not NOT_AN_ANSWER.search(body):
            return True
    return False


def copilot(timeline, reviews, now):
    requests = [e for e in timeline if e.get("event") == "review_requested"
                and authored_by((e.get("requested_reviewer") or {}).get("login"), "copilot")]
    if not requests:
        return None
    last = requests[-1]
    reviewed = [epoch(r.get("submitted_at")) for r in reviews if authored_by(r["user"]["login"], "copilot")]
    since_review = [e for e in requests if epoch(e["created_at"]) > max(reviewed or [0])]
    return {"reviewer": "copilot", "asked_id": "copilot-%d" % epoch(last["created_at"]), "asked": last["created_at"],
            "answered": not since_review, "waiting": now - epoch(last["created_at"]), "chases": max(0, len(since_review) - 1)}


def status(comments_path, reviews_path, timeline_path, me, head, now, reviewers):
    comments, reviews, now = json.load(open(comments_path)), json.load(open(reviews_path)), int(now)
    for reviewer in reviewers:
        if reviewer == "copilot":
            row = copilot(json.load(open(timeline_path)), reviews, now)
            if row:
                print(json.dumps(row))
            continue
        requests = [c for c in comments if is_request(c, me, reviewer)]
        if not requests:
            continue
        last, chases = requests[-1], 0
        for c in reversed(requests):
            if CHASE % reviewer not in (c.get("body") or ""):
                break
            chases += 1
        print(json.dumps({"reviewer": reviewer, "asked_id": last["id"], "asked": last["created_at"],
                          "answered": answered(reviewer, last, comments, reviews, head),
                          "waiting": now - epoch(last["created_at"]), "chases": chases}))


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command == "status":
        status(args[0], args[1], args[2], args[3], args[4], args[5], args[6:])
    else:
        sys.exit("flow: unknown command %s" % command)


main()

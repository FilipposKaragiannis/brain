# _review_fixture.sh: readers and writers of the fake gh's pull request: pr_field, asked, seed, posted and
# answered. Takes $P and FAKE_GH_DIR. Sourced after _github_fixture.sh, never run.
pr_field() { python3 -c "import json,sys; print(json.dumps(json.load(open('$FAKE_GH_DIR/issues.json'))['pr'].get(sys.argv[1])))" "$1"; }
asked() { python3 -c "import json,re; print(' '.join(re.findall(r'flow:review-request (\S+) -->', ' '.join(json.load(open('$FAKE_GH_DIR/issues.json'))['pr'].get('comments', [])))))"; }
seed() { # seed <request age s> <codex status> <+1 count> [chase|reply <body>|lookalike]: one request by the owner and the Codex summary
  python3 - "$FAKE_GH_DIR/issues.json" "$@" <<'PY2'
import json, sys, time
p, age, status, plus, extra = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5:]
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
asked = time.time() - age
owner, codex = {"login": "owner", "type": "User"}, {"login": "chatgpt-codex-connector[bot]", "type": "Bot"}
d = json.load(open(p)); pr = d["pr"]; pr["headRefOid"] = "abc1234def5678"; pr["comments"] = []; pr["reviews"] = []
state = '{"code_review":{"commit_sha":"abc1234def5678","status":"%s"}}' % status
pr["rest_comments"] = [{"id": 7, "user": owner, "body": "@codex please review", "created_at": iso(asked), "updated_at": iso(asked), "reactions": {"+1": plus}},
                       {"id": 8, "user": codex, "created_at": iso(asked - 3600), "updated_at": iso(asked + 5),
                        "body": "<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 %s -->" % state, "reactions": {}}]
later = lambda user, body: {"id": 9, "user": user, "body": body, "created_at": iso(asked + 1), "updated_at": iso(asked + 1), "reactions": {}}
if extra[:1] == ["chase"]:
    pr["rest_comments"].append(later(owner, "@codex review\n\n<!-- flow:chase codex -->"))
elif extra[:1] == ["reply"]:
    pr["rest_comments"].append(later(codex, extra[1]))
elif extra[:1] == ["lookalike"]:
    pr["rest_comments"].append(later({"login": "xcodex", "type": "User"}, "Looks good to me."))
json.dump(d, open(p, "w"))
PY2
}
posted() { python3 -c "import json; print(len(json.load(open('$FAKE_GH_DIR/issues.json'))['pr']['comments']))"; }
answered() { "$P/scripts/comments.sh" reviews 91 | python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['answered'])"; }

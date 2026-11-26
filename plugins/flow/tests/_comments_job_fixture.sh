# _comments_job_fixture.sh: the GitHub state the jobs on fake hosts start from: the epic gh#20 with
# its children gh#21 and gh#22, two resolved review threads, and the pull request #91 that Codex
# linked to gh#21, as the review requests and chases leave it. Takes $P and FAKE_GH_DIR, and runs
# in the repo. Sourced after _review_fixture.sh, never run.
export FLOW_GH_RETRY_WAIT="0 0"
review_request_age_seconds=7200
printf '{"issues": [{"number": 20, "title": "Epic", "body": "", "state": "OPEN", "labels": ["epic"], "url": "https://gh/20", "id": 1020, "node": "I_20"}]}' > "$FAKE_GH_DIR/issues.json"
"$P/adapters/github/create.sh" task "Slice one" --size S --parent 'gh#20' --body "## What
x" >/dev/null
"$P/adapters/github/create.sh" task "Slice two" --blocked-by 'gh#21' >/dev/null
python3 -I - "$FAKE_GH_DIR/issues.json" <<'PYTHON'
import json
import sys

state_path = sys.argv[1]
with open(state_path, encoding="utf-8") as state_file:
    state = json.load(state_file)
state["threads"] = [
    {"id": "T_1", "isResolved": False, "isOutdated": False, "path": "src/A.cs", "line": 3,
     "comments": {"nodes": [{"databaseId": 501, "body": "Magic number here", "author": {"login": "codex"}, "createdAt": "t"}]}},
    {"id": "T_2", "isResolved": True, "isOutdated": False, "path": "src/B.cs", "line": 1,
     "comments": {"nodes": [{"databaseId": 502, "body": "old", "author": {"login": "claude"}, "createdAt": "t"}]}},
]
state["pr"] = None
with open(state_path, "w", encoding="utf-8") as state_file:
    json.dump(state, state_file)
PYTHON
"$P/scripts/comments.sh" reply 90 501 "fixed in abc123"
"$P/scripts/comments.sh" resolve T_1
printf 'the body' | gh pr create --base main --head flow/x --title T --body-file - >/dev/null
"$P/scripts/state.sh" set 'gh#21' pr=https://gh/pull/91 pr_host=codex >/dev/null
seed "$review_request_age_seconds" running 0 chase
python3 -I - "$FAKE_GH_DIR/issues.json" "$review_request_age_seconds" "$(date +%s)" <<'PYTHON'
import json
import sys
import time


def timestamp(moment: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(moment))


state_path, age, now = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(state_path, encoding="utf-8") as state_file:
    state = json.load(state_file)
state["pr"].update(
    headRefName="bugfix/12-x",
    body="Adds the slide.\n\n\U0001f916 Generated with [Claude Code](https://claude.com/claude-code)",
    comments=[],
    reviewers=["@copilot"],
    timeline=[{"event": "review_requested", "requested_reviewer": {"login": "Copilot", "type": "Bot"}, "created_at": timestamp(now - age)}],
    reviews=[{"user": {"login": "copilot-pull-request-reviewer[bot]", "type": "Bot"}, "submitted_at": timestamp(now)}],
)
with open(state_path, "w", encoding="utf-8") as state_file:
    json.dump(state, state_file)
PYTHON

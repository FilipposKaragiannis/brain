#!/bin/sh
# Fixture: the item's fix is on its task branch and pushed, PR 7 is open for it, and one review
# thread asks for the test the acceptance names and tests/run.sh lacks: a valid comment.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" pr implemented
set -e
github '{"issues": [{"number": 7, "title": "Greet strangers when no name is given", "body": "", "state": "OPEN", "labels": [], "url": "https://gh/pull/7", "comments": []}],
 "pr": {"number": 7, "state": "OPEN", "isDraft": false, "mergedAt": null, "url": "https://gh/pull/7", "headRefName": "flow/local-task-1", "baseRefName": "main"},
 "threads": [{"id": "T_1", "isResolved": false, "isOutdated": false, "path": "tests/run.sh", "line": 2, "comments": {"nodes": [
   {"databaseId": 501, "author": {"login": "reviewer"}, "createdAt": "2026-10-17T10:00:00Z",
    "body": "The acceptance says greet with no argument prints \"hello stranger\", and no test checks it. Add one here."}]}}]}'
git -C .pool/wt-1 push -q origin flow/local-task-1
rm -f .flow/runs/*.json
"$P/adapters/local/write-state.sh" local:task/1 gate=merge pr=https://gh/pull/7 >/dev/null

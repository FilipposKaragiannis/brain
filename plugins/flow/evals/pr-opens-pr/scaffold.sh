#!/bin/sh
# Fixture: the item at its pr step with the fix committed on the task branch and a passing verify
# report, an origin to push to and no PR yet. Issue 91 stands for the conversation of the PR the
# fake opens, so review requests can go there as comments.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" pr implemented
set -e
github '{"issues": [{"number": 91, "title": "", "body": "", "state": "OPEN", "labels": [], "url": "https://gh/pull/91", "comments": []}], "pr": null}'
(cd .pool/wt-1 && "$P/scripts/verify.sh" local:task/1 >/dev/null)

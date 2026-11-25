#!/bin/sh
# Fixture: the item at its pr step with a passing verify report whose proof table proves every
# acceptance line by test, and no Not checked section, so the body's Not checked list must say
# nothing on its own.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" pr implemented
set -e
github '{"issues": [{"number": 91, "title": "", "body": "", "state": "OPEN", "labels": [], "url": "https://gh/pull/91", "comments": []}], "pr": null}'
wt=.pool/wt-1
(cd "$wt" && "$P/scripts/verify.sh" local:task/1 >/dev/null)
head="$(git -C "$wt" rev-parse --short HEAD)"
cat > "$wt/.flow/reports/local-task-1/verify.md" <<REPORT
Verdict: pass at $head, 2 of 2 acceptance lines proven live or by test

| acceptance line | grade | proof |
|---|---|---|
| greet prints "hello <name>" for any name | test | \`tests/run.sh\` passed |
| greet with no argument prints "hello stranger" | test | \`tests/run.sh\` passed |
REPORT

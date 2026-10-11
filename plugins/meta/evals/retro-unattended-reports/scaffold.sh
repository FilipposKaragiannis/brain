#!/bin/sh
# Fixture: a project with a lessons log from the flow.
set -e
git init -q -b main .
git config user.email eval@example.com
git config user.name eval
mkdir -p .flow docs
printf '# Project\n' > AGENTS.md
cat > .flow/lessons.jsonl <<'J'
{"time":"2026-10-08T10:00:00Z","kind":"review-blocker","item":"gh#301","step":"review","rule":"N-06","text":"Magic number 0.9 in OrderPricer.Price; the discount rate is not named","host":"claude"}
{"time":"2026-10-09T09:10:00Z","kind":"review-blocker","item":"gh#304","step":"review","rule":"N-06","text":"Magic numbers 3 and 7 in RetryPolicy; attempt counts not named","host":"codex"}
{"time":"2026-10-09T16:00:00Z","kind":"escalation","item":"gh#305","step":"verify","rule":"","text":"Step verify failed 3 times. Last: gate determinism: replay mismatch at tick 1200 because the physics seed was read from the clock","host":"claude"}
{"time":"2026-10-10T11:00:00Z","kind":"review-blocker","item":"gh#306","step":"review","rule":"N-06","text":"Magic number 60 in SessionTimeout; seconds per minute not named","host":"claude"}
J
git add -A && git commit -qm "chore: initial"

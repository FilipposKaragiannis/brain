#!/bin/sh
# Fixture: the flow fixture with one open item (local:task/1, greet strangers), a decision record,
# and four notes parsed the way jobs/intake.sh hands them to the skill on a local tracker (no
# types, no areas, flow's default rules): one to file, one question, one duplicate of the open
# item, and one the decision record retired.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
set -e
printf '# Decisions\n\n- 2026-09-02: greet prints plain text only, never colours, because its output is piped into other tools.\n' > docs/decisions.md
cat > notes.md <<'MD'
# Notes

## Greet
- #bug greet with two names greets only the first: `sh src/greet.sh ann lee` prints "hello ann"
- What does tests/run.sh check?
- greet a stranger when the name is missing
- #idea print the greeting in green
MD
git add -A && git commit -qm "docs: decisions and notes"
run=.flow/tmp/intake-eval; mkdir -p "$run" .flow/log
printf '.flow/tmp/\n.flow/log/\n' >> .git/info/exclude
python3 -I "$P/scripts/_intake.py" parse notes.md .flow/log/intake-ledger.jsonl 10 | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
d.update(types=[], areas=[], rules=sys.argv[1])
print(json.dumps(d, indent=1))' "$P/skills/intake/rules.md" > "$run/notes.json"

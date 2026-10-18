#!/bin/sh
# Tests for the repo tools: lint catches a broken plugin, the cost report parses and never
# fails. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

echo "lint on a broken plugin"
out="$work/lint.out"
python3 "$root/tools/lib/check_plugins.py" "$here/fixtures/broken" > "$out"; code=$?
check "fails" [ "$code" -eq 1 ]
check "a missing hook script" grep -q 'hook script missing: .*missing.sh' "$out"
check "a hook script that is not executable" grep -q 'hook script not executable: .*not-executable.sh' "$out"
check "a hook command outside the plugin" grep -q 'hook command does not name a script in the plugin: .*echo outside' "$out"
check "a missing path in an installer" grep -q 'init.sh names a missing plugin path: templates/missing.yaml' "$out"
check "a missing path under CLAUDE_PLUGIN_ROOT" grep -q 'SKILL.md names a missing plugin path: scripts/gone.sh' "$out"
check "nothing else" [ "$(wc -l < "$out" | tr -d ' ')" -eq 5 ]
check "passes on the marketplace" python3 "$root/tools/lib/check_plugins.py" "$root"

echo "cost report"
mkdir -p "$work/bin"
fake() { printf '#!/bin/sh\n%s\n' "$1" > "$work/bin/claude"; chmod +x "$work/bin/claude"; }
# A /context report: rows of every plugin, the agent and skill tables, a k suffix, a repeat.
cat > "$work/context.md" <<'MD'
### Custom Agents
| Agent Type | Source | Tokens |
| flow:planner | Plugin | 600 |
| other:planner | Plugin | 9000 |
### Skills
| Skill | Source | Tokens |
| flow:do | Plugin (flow) | ~1.2k |
| flow:do | Plugin (flow) | ~1.2k |
| flow:new | Plugin (flow) | ~100 |
MD
fake "cat '$work/context.md'"
out="$(PATH="$work/bin:$PATH" "$root/tools/cost.sh" 1000)"; code=$?
check "exits 0" [ "$code" -eq 0 ]
check "sums the plugin's rows once each" sh -c "printf '%s' \"\$0\" | grep -q 'cost: warning: flow always-on ~1900 tok, over the 1000 budget'" "$out"
check "reports under the budget" sh -c "printf '%s' \"\$0\" | grep -q 'cost: flow always-on ~1900 tok\$'" "$(PATH="$work/bin:$PATH" "$root/tools/cost.sh" 3000)"
check "a plugin with no rows: no line" sh -c "! printf '%s' \"\$0\" | grep -q 'craft'" "$out"
out="$(PATH="$work/bin:$PATH" "$root/tools/cost.sh" flow 3000)"
check "a named plugin only, with a budget" [ "$out" = "cost: flow always-on ~1900 tok" ]
out="$(PATH="$work/bin:$PATH" "$root/tools/cost.sh" nope 2>&1)"; code=$?
check "an unknown plugin: exit 2" [ "$code-$out" = "2-cost: no plugin named nope" ]
fake 'echo "a format nobody expected"'
out="$(PATH="$work/bin:$PATH" "$root/tools/cost.sh")"; code=$?
check "unparsed output: silent, exit 0" [ "$code-$out" = "0-" ]
fake 'exit 1'
out="$(PATH="$work/bin:$PATH" "$root/tools/cost.sh")"; code=$?
check "failing CLI: silent, exit 0" [ "$code-$out" = "0-" ]
rm "$work/bin/claude"
out="$(PATH="$work/bin:/usr/bin:/bin" "$root/tools/cost.sh")"; code=$?
check "no CLI: silent, exit 0" [ "$code-$out" = "0-" ]

echo "eval summary"
out="$(python3 "$root/tools/lib/eval_summary.py" "$here/fixtures/eval-result")"; code=$?
has() { printf '%s\n' "$out" | grep -q -- "$1"; }
check "exits 0" [ "$code" -eq 0 ]
check "a login failure is BLOCKED, not a 0" has 'retro-unattended-reports \[with\] *score 0.75, passed 1/2, BLOCKED 1 (exit 1: Not logged in'
check "max turns stays scored" has 'review-cites-rule-ids \[with\] *score 0.67, passed 1/2$'
check "the case timeout stays scored" has 'plan-writes-design \[with\] *score 0.50, passed 0/1$'
check "the baseline arm is scored apart" has 'review-cites-rule-ids \[without\] *score 0.25, passed 0/1$'
check "a case with only BLOCKED runs has no score" has 'init-installs \[with\] *no scored run, BLOCKED 1'
check "a sandbox-broken tool is BLOCKED" has "verify-writes-report \\[with\\] *score 1.00, passed 1/1, BLOCKED 1 (sandbox: Failed to locate 'git')"
check "the totals" has 'cases passed 1/4 over scored runs; 7 runs scored, 3 BLOCKED'
python3 "$root/tools/lib/eval_summary.py" "$work/nothing-here" >/dev/null; code=$?
check "no result: exit 1" [ "$code" -eq 1 ]
EVAL_BASELINE="$work/baseline.json" python3 "$root/tools/lib/eval_summary.py" "$here/fixtures/eval-result" --save >/dev/null
check "--save writes the scored runs" python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['plugins']['demo']; assert d['retro-unattended-reports']['with'] == {'score': 0.75, 'passed': 1, 'runs': 2}" "$work/baseline.json"
out="$(python3 "$root/tools/lib/eval_summary.py" "$here/fixtures/eval-result" --against "$work/baseline.json")"
check "compares with the baseline" has 'review-cites-rule-ids \[without\] *score 0.25, passed 0/1 (baseline 0.25, +0.00)$'

echo "eval.sh prints the summary and keeps the eval's exit status"
cat > "$work/bin/claude" <<EOF
#!/bin/sh
out=""; prev=""
for arg in "\$@"; do [ "\$prev" = "--output-dir" ] && out="\$arg"; prev="\$arg"; done
printf '%s\n' "\$*" > "$work/eval-args"
command -v gh launchctl crontab > "$work/eval-path"
mkdir -p "\$out" && cp "$here/fixtures/eval-result/aggregate-result.json" "\$out/"
exit 1
EOF
chmod +x "$work/bin/claude"
out="$(PATH="$work/bin:$PATH" "$root/tools/eval.sh" demo --output-dir "$work/eval-out")"; code=$?
check "exit status of the eval" [ "$code" -eq 1 ]
check "prints the summary" has 'cases passed 1/4 over scored runs; 7 runs scored, 3 BLOCKED'
check "grants Write and Edit" grep -q -- '--allow-tools Bash Read Glob Grep Agent Write Edit ' "$work/eval-args"
check "the sessions get the stand-ins for gh, launchctl and crontab" [ "$(grep -c "^$root/tools/eval-bin/" "$work/eval-path")" -eq 3 ]
printf '#!/bin/sh\nexit 0\n' > "$work/bin/claude"
out="$(PATH="$work/bin:$PATH" "$root/tools/eval.sh" demo --output-dir "$work/eval-none")"; code=$?
check "no new result: says so, exit 0" [ "$code" -eq 0 ]
check "no new result: message" has 'no new aggregate-result.json'
rm "$work/bin/claude"

[ "$fails" -eq 0 ] && echo "tools: ok"
exit $(( fails > 0 ))

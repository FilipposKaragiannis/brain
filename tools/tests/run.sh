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
fake 'printf "Projected token cost\n  Always-on:   ~2,603 tok   added to every session\n"'
out="$(PATH="$work/bin:$PATH" "$root/tools/cost.sh" 2000)"; code=$?
check "exits 0" [ "$code" -eq 0 ]
check "warns over the budget" sh -c "printf '%s' \"\$0\" | grep -q 'cost: warning: flow always-on ~2603 tok, over the 2000 budget'" "$out"
check "reports under the budget" sh -c "printf '%s' \"\$0\" | grep -q 'cost: flow always-on ~2603 tok\$'" "$(PATH="$work/bin:$PATH" "$root/tools/cost.sh" 3000)"
fake 'echo "Always-on:  ~1.2k tok"'
check "reads a k suffix" sh -c "printf '%s' \"\$0\" | grep -q 'craft always-on ~1200 tok'" "$(PATH="$work/bin:$PATH" "$root/tools/cost.sh" 2000)"
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
check "the totals" has 'cases passed 0/3 over scored runs; 6 runs scored, 2 BLOCKED'
python3 "$root/tools/lib/eval_summary.py" "$work/nothing-here" >/dev/null; code=$?
check "no result: exit 1" [ "$code" -eq 1 ]

echo "eval.sh prints the summary and keeps the eval's exit status"
cat > "$work/bin/claude" <<EOF
#!/bin/sh
out=""; prev=""
for arg in "\$@"; do [ "\$prev" = "--output-dir" ] && out="\$arg"; prev="\$arg"; done
printf '%s\n' "\$*" > "$work/eval-args"
mkdir -p "\$out" && cp "$here/fixtures/eval-result/aggregate-result.json" "\$out/"
exit 1
EOF
chmod +x "$work/bin/claude"
out="$(PATH="$work/bin:$PATH" "$root/tools/eval.sh" demo --output-dir "$work/eval-out")"; code=$?
check "exit status of the eval" [ "$code" -eq 1 ]
check "prints the summary" has 'cases passed 0/3 over scored runs; 6 runs scored, 2 BLOCKED'
check "grants Write and Edit" grep -q -- '--allow-tools Bash Read Glob Grep Agent Write Edit ' "$work/eval-args"
printf '#!/bin/sh\nexit 0\n' > "$work/bin/claude"
out="$(PATH="$work/bin:$PATH" "$root/tools/eval.sh" demo --output-dir "$work/eval-none")"; code=$?
check "no new result: says so, exit 0" [ "$code" -eq 0 ]
check "no new result: message" has 'no new aggregate-result.json'
rm "$work/bin/claude"

[ "$fails" -eq 0 ] && echo "tools: ok"
exit $(( fails > 0 ))

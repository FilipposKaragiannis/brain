#!/bin/sh
# Tests for the repo tools: lint catches a broken plugin, the cost report parses and never
# fails, release.sh folds the changelog fragments and lint checks them. Exit 1 on any failure.
set -u
export PYTHONDONTWRITEBYTECODE=1   # a __pycache__ in the repo copy would read as "written" to the diffs below
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
for t in gh launchctl crontab; do command -v "\$t"; done > "$work/eval-path"
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

echo "release folds the changelog fragments"
# A copy of this repo without its own fragments, plus the demo plugin at 1.4.2: release.sh, the
# generator and lint.sh run in the copy as they run here.
seed="$work/seed"; mkdir -p "$seed"
(cd "$root" && git ls-files -co --exclude-standard | while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done | tar -cf - -T -) | tar -xf - -C "$seed"
rm -rf "$seed"/plugins/*/changelog.d
cp -R "$here/fixtures/release/demo" "$seed/plugins/demo"
"$seed/tools/generate.sh" >/dev/null
repo="$work/repo"; demo="$repo/plugins/demo"; today="$(date +%F)"
fresh() { rm -rf "$repo"; cp -R "$seed" "$repo"; mkdir -p "$demo/changelog.d"; }
version() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$1/plugin.source.json"; }
release() { out="$("$repo/tools/release.sh" "$@" 2>"$work/release.err")"; code=$?; }
package_versions() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(' '.join([d['version']] + ([d['packages']['']['version']] if 'packages' in d else [])))" "$1"; }

fresh
printf 'bump: patch\n\n- A fix.\n' > "$demo/changelog.d/a-fix.md"
printf 'bump: minor\n\n- A feature whose line\n  wraps.\n' > "$demo/changelog.d/b-feature.md"
release demo
check "exits 0" [ "$code" -eq 0 ]
check "prints the plugin, the old and the new version" [ "$out" = "demo 1.4.2 -> 1.5.0" ]
check "minor wins over patch" [ "$(version "$demo")" = 1.5.0 ]
check "the section goes on top, the fragments in filename order" [ "$(cat "$demo/CHANGELOG.md")" = "$(printf '# demo\n\n## 1.5.0 (%s)\n\n- A fix.\n- A feature whose line\n  wraps.\n\n## 1.4.2 (2026-10-30)\n\n- The release before the fragments.' "$today")" ]
check "the fragments are gone" [ ! -e "$demo/changelog.d" ]
check "generate ran: the manifest carries the new version" grep -q '"version": "1.5.0"' "$demo/.claude-plugin/plugin.json"
check "generate ran: every generated file is fresh" python3 "$repo/tools/lib/generate.py" --check
check "the app's package.json takes the new version" [ "$(package_versions "$demo/app/package.json")" = 1.5.0 ]
check "the app's lockfile takes it at the top and in its root package" [ "$(package_versions "$demo/app/package-lock.json")" = "1.5.0 1.5.0" ]
check "a package in a folder of the app takes it" [ "$(package_versions "$demo/app/ui/package.json")" = 1.5.0 ]
check "a dependency's version in the lockfile stays" [ "$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['packages']['node_modules/typescript']['version'])" "$demo/app/package-lock.json")" = 5.9.3 ]
check "the package.json keeps npm's formatting" grep -q '^  "engines": { "node": ">=24" }$' "$demo/app/package.json"

fresh
printf 'bump: patch\n\n- A fix.\n' > "$demo/changelog.d/a-fix.md"
printf 'bump: patch\n\n- Another fix.\n' > "$demo/changelog.d/b-fix.md"
release demo
check "patch only raises the patch" [ "$code-$(version "$demo")" = "0-1.4.3" ]

fresh
printf 'bump: major\n\n- A break.\n' > "$demo/changelog.d/a-break.md"
printf 'bump: minor\n\n- A feature.\n' > "$demo/changelog.d/b-feature.md"
release demo
check "major wins and resets minor and patch" [ "$code-$(version "$demo")" = "0-2.0.0" ]

fresh
rm "$demo/CHANGELOG.md"
printf 'bump: patch\n\n- A fix.\n' > "$demo/changelog.d/a-fix.md"
release demo
check "a plugin without a CHANGELOG gets one under its heading" [ "$(cat "$demo/CHANGELOG.md")" = "$(printf '# demo\n\n## 1.4.3 (%s)\n\n- A fix.' "$today")" ]

fresh
mkdir -p "$repo/plugins/craft/changelog.d"
printf 'bump: patch\n\n- A demo fix.\n' > "$demo/changelog.d/a-fix.md"
printf 'bump: minor\n\n- A craft feature.\n' > "$repo/plugins/craft/changelog.d/a-feature.md"
release
check "no plugin named: every plugin with fragments" [ "$code-$out" = "0-craft $(version "$seed/plugins/craft") -> $(version "$repo/plugins/craft")
demo 1.4.2 -> 1.4.3" ]

fresh
release
check "no fragments: nothing to release, exit 0" [ "$code-$out" = "0-release: nothing to release" ]
check "no fragments: nothing written" diff -r -x changelog.d "$seed" "$repo"

fresh
printf 'bump: patch\n\n- A fix.\n' > "$demo/changelog.d/a-fix.md"
printf 'bump: minor\n- No blank line.\n' > "$demo/changelog.d/b-bad.md"
release demo
check "a malformed fragment: exit 2" [ "$code" -eq 2 ]
check "a malformed fragment: the file and the reason" grep -q '^release: plugins/demo/changelog.d/b-bad.md: a blank line and then the bullets must follow the bump line$' "$work/release.err"
check "a malformed fragment: nothing written" diff -r -x changelog.d "$seed" "$repo"
check "a malformed fragment: the good one is kept" [ -f "$demo/changelog.d/a-fix.md" ]

fresh
printf 'bump: patch\n\n- A fix.\n' > "$demo/changelog.d/a-fix.md"
printf '{"name": "demo-ui", "version": "1.4.2"}\n' > "$demo/app/ui/package.json"
release demo
check "an app package with its version elsewhere: exit 2 naming it" sh -c "[ $code -eq 2 ] && grep -q '^release: plugins/demo/app/ui/package.json: no version field where npm writes it\$' '$work/release.err'"
check "an app package with its version elsewhere: nothing written" [ "$(version "$demo")" = 1.4.2 ]

release nope
check "an unknown plugin: exit 2" [ "$code-$(cat "$work/release.err")" = "2-release: no plugin named nope" ]

fresh
printf 'bump: minor\n\n- A feature.\n' > "$demo/changelog.d/a-feature.md"
release --dry-run demo
check "dry run: exit 0 and the plugin line first" [ "$code-$(printf '%s\n' "$out" | head -1)" = "0-demo 1.4.2 -> 1.5.0" ]
check "dry run: prints the section" sh -c "printf '%s' \"\$0\" | grep -q '^- A feature.\$'" "$out"
check "dry run: nothing written" diff -r -x changelog.d "$seed" "$repo"
check "dry run: the fragment stays" [ -f "$demo/changelog.d/a-feature.md" ]

echo "lint checks the changelog fragments"
lint_fragments() { out="$(python3 "$repo/tools/lib/fragments.py" "$repo")"; code=$?; }
fresh
printf 'bump: minor\n\n- A feature.\n  - A nested point.\n' > "$demo/changelog.d/a-feature.md"
lint_fragments
check "a well-formed fragment passes" [ "$code-$out" = "0-" ]
printf 'bump: big\n\n- A feature.\n' > "$demo/changelog.d/a-feature.md"
lint_fragments
check "an unknown bump fails" [ "$code-$out" = "1-lint: malformed changelog fragment plugins/demo/changelog.d/a-feature.md: the first line must be 'bump: major', 'bump: minor' or 'bump: patch'" ]
printf 'bump: minor\n\n- A feature.\nA paragraph.\n' > "$demo/changelog.d/a-feature.md"
lint_fragments
check "a line that is no bullet fails" [ "$code-$out" = "1-lint: malformed changelog fragment plugins/demo/changelog.d/a-feature.md: line 4 is neither a bullet ('- ') nor a continuation (indented two spaces)" ]
printf 'bump: minor\n\n- %0100d\n' 0 > "$demo/changelog.d/a-feature.md"
lint_fragments
check "a line over 100 columns fails" [ "$code-$out" = "1-lint: malformed changelog fragment plugins/demo/changelog.d/a-feature.md: line 3 is over 100 columns" ]
rm "$demo/changelog.d/a-feature.md"; : > "$demo/changelog.d/notes.txt"
lint_fragments
check "a file that is not .md fails" [ "$code-$out" = "1-lint: a changelog.d holds only .md files: plugins/demo/changelog.d/notes.txt" ]
rm "$demo/changelog.d/notes.txt"
check "app packages at the plugin's version pass" python3 "$repo/tools/lib/packages.py" "$repo"
sed 's/"version": "1.4.2"/"version": "1.4.1"/' "$seed/plugins/demo/app/package-lock.json" > "$demo/app/package-lock.json"
out="$(python3 "$repo/tools/lib/packages.py" "$repo")"; code=$?
check "an app lockfile behind the plugin fails" [ "$code-$out" = "1-lint: plugins/demo/app/package-lock.json: version 1.4.1 and 1.4.1, the plugin is 1.4.2" ]
printf 'bump: minor\n- No blank line.\n' > "$demo/changelog.d/b-bad.md"
out="$("$repo/tools/lint.sh" 2>/dev/null)"; code=$?
check "tools/lint.sh fails on a malformed fragment and names it" sh -c "[ $code -eq 1 ] && printf '%s' \"\$0\" | grep -q 'malformed changelog fragment plugins/demo/changelog.d/b-bad.md'" "$out"
check "tools/lint.sh fails on a drifted app package and names it" sh -c "[ $code -eq 1 ] && printf '%s' \"\$0\" | grep -q 'plugins/demo/app/package-lock.json: version 1.4.1'" "$out"

[ "$fails" -eq 0 ] && echo "tools: ok"
exit $(( fails > 0 ))

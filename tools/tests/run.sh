#!/bin/sh
# Tests for the repo tools: lint catches a broken plugin, the cost report parses and never
# fails, release.sh folds the changelog fragments and lint checks them. Exit 1 on any failure.
set -u
export PYTHONDONTWRITEBYTECODE=1   # a __pycache__ in the repo copy would read as "written" to the diffs below
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT
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
check "RunWithoutCliVersion_NamesNoChange: a run that does not say its version has none to compare" sh -c '! printf "%s\n" "$1" | grep -q "Claude Code changed"' _ "$out"
mkdir -p "$work/on-old" "$work/on-new" "$work/on-new-blocked" "$work/on-new-partial"
on_version() { version="$1"; output_directory="$2"; shift 2; python3 -c "import json,sys; aggregate_result=json.load(open(sys.argv[1])); kept=sys.argv[4:]; aggregate_result['claudeVersion']=sys.argv[2]; aggregate_result['cases']=[case for case in aggregate_result['cases'] if not kept or case['name'] in kept]; json.dump(aggregate_result,open(sys.argv[3],'w'))" "$here/fixtures/eval-result/aggregate-result.json" "$version" "$output_directory/aggregate-result.json" "$@"; }
recorded_versions() { python3 -c "import json,sys; cases=json.load(open(sys.argv[1]))['plugins']['demo']; print(' '.join(sorted({arm.get('claude_version', '-') for arms in cases.values() for arm in arms.values()})))" "$work/baseline.json"; }
on_version 2.1.303 "$work/on-old"; on_version 2.1.325 "$work/on-new"
EVAL_BASELINE="$work/baseline.json" python3 "$root/tools/lib/eval_summary.py" "$work/on-old" --save >/dev/null
check "SaveOnACliVersion_RecordsThatVersion: the baseline keeps the version its scores came from" python3 -c "import json,sys; recorded=json.load(open(sys.argv[1]))['plugins']['demo']['review-cites-rule-ids']['with'].get('claude_version'); assert recorded == '2.1.303', 'the save ran on 2.1.303, so the score names it, not %s' % recorded" "$work/baseline.json"
out="$(python3 "$root/tools/lib/eval_summary.py" "$work/on-new" --against "$work/baseline.json")"
check "RunOnNewerCli_NamesTheChangeBeforeTheCases: the version line comes first, since it qualifies every case line" sh -c 'printf "%s\n" "$1" | sed -n 2p | grep -q "Claude Code changed since the baseline (2.1.303 -> 2.1.325)"' _ "$out"
out="$(python3 "$root/tools/lib/eval_summary.py" "$work/on-old" --against "$work/baseline.json")"
check "RunOnTheBaselineCli_NamesNoChange: the same version cannot explain a score move" sh -c '! printf "%s\n" "$1" | grep -q "Claude Code changed"' _ "$out"
on_version 2.1.325 "$work/on-new-blocked" init-installs
EVAL_BASELINE="$work/baseline.json" python3 "$root/tools/lib/eval_summary.py" "$work/on-new-blocked" --save >/dev/null
check "SaveOfOnlyBlockedRunsOnNewerCli_KeepsTheRecordedVersions: a save that replaces no score relabels none" [ "$(recorded_versions)" = "2.1.303" ]
on_version 2.1.325 "$work/on-new-partial" review-cites-rule-ids
EVAL_BASELINE="$work/baseline.json" python3 "$root/tools/lib/eval_summary.py" "$work/on-new-partial" --save >/dev/null
out="$(python3 "$root/tools/lib/eval_summary.py" "$work/on-new" --against "$work/baseline.json")"
check "PartialSaveOnNewerCli_RunStillNamesTheOlderVersion: the cases the save left keep the version they were scored on" sh -c 'printf "%s\n" "$1" | sed -n 2p | grep -q "Claude Code changed since the baseline (2.1.303 -> 2.1.325)"' _ "$out"
out="$(python3 "$root/tools/lib/eval_summary.py" "$work/on-new-partial" --against "$work/baseline.json")"
check "PartialSaveOnNewerCli_RunOfTheSavedCaseNamesNoChange: its baseline scores came from the same version" sh -c '! printf "%s\n" "$1" | grep -q "Claude Code changed"' _ "$out"

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
fresh() { rm -rf "$repo"; cp -R "$seed" "$repo"; git init -q "$repo"; mkdir -p "$demo/changelog.d"; }
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
check "no fragments: nothing written" diff -r -x changelog.d -x .git "$seed" "$repo"

fresh
printf 'bump: patch\n\n- A fix.\n' > "$demo/changelog.d/a-fix.md"
printf 'bump: minor\n- No blank line.\n' > "$demo/changelog.d/b-bad.md"
release demo
check "a malformed fragment: exit 2" [ "$code" -eq 2 ]
check "a malformed fragment: the file and the reason" grep -q '^release: plugins/demo/changelog.d/b-bad.md: a blank line and then the bullets must follow the bump line$' "$work/release.err"
check "a malformed fragment: nothing written" diff -r -x changelog.d -x .git "$seed" "$repo"
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
check "dry run: nothing written" diff -r -x changelog.d -x .git "$seed" "$repo"
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

echo "lint keeps every suite in the sandbox"
fresh
mkdir -p "$demo/tests"
printf '#!/bin/sh\nwork="$(mktemp -d)"\necho ok\n' > "$demo/tests/run.sh"
out="$("$repo/tools/lint.sh" 2>/dev/null)"; code=$?
check "SuiteOutsideSandbox_FailsLint: lint exits 1 and names a suite that never enters tools/lib/sandbox.sh" sh -c "[ $code -eq 1 ] && printf '%s' \"\$0\" | grep -q 'sandbox.*plugins/demo/tests/run.sh'" "$out"
fresh
mkdir -p "$demo/tests"
printf '#!/bin/sh\nwork="$(mktemp -d)"\n. "$here/../../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$here/.."\necho ok\n' > "$demo/tests/run.sh"
out="$("$repo/tools/lint.sh" 2>/dev/null)"; code=$?
check "SuiteWithoutCloseTrap_FailsLint: lint exits 1 and names a suite that enters the sandbox but never checks the checkout on exit" sh -c "[ $code -eq 1 ] && printf '%s' \"\$0\" | grep -q 'sandbox.*plugins/demo/tests/run.sh'" "$out"
fresh
python3 - "$demo/app/package.json" <<'PY2'
import json, sys
package = json.load(open(sys.argv[1]))
package["scripts"] = {"test": "node --test 'test/**/*.test.ts'"}
json.dump(package, open(sys.argv[1], "w"), indent=2)
PY2
out="$("$repo/tools/lint.sh" 2>/dev/null)"; code=$?
check "AppTestScriptOutsideSandbox_FailsLint: lint exits 1 and names an app whose test script skips tools/lib/sandboxed.sh" sh -c "[ $code -eq 1 ] && printf '%s' \"\$0\" | grep -q 'sandbox.*plugins/demo/app/package.json'" "$out"
fresh
flow_dispatcher="$repo/plugins/flow/tests/run.sh"
out="$("$repo/tools/lint.sh" 2>/dev/null)"; committed_tree_code=$?; committed_tree_out="$out"
check "FlowDispatcherHoldingOnlyTheDispatch_IsNotNamedByLint: the flow run.sh that only hands the run to flow_suites.py needs no sandbox lines" sh -c "! printf '%s' \"\$0\" | grep -q 'plugins/flow/tests/run.sh'" "$out"
mkdir -p "$demo/tests"
cp "$flow_dispatcher" "$demo/tests/run.sh"
out="$("$repo/tools/lint.sh" 2>/dev/null)"; code=$?
check "SuiteCopyingTheFlowDispatcher_FailsLint: lint exits 1 and names any other file that holds the dispatch outside the sandbox" sh -c "[ $code -eq 1 ] && printf '%s' \"\$0\" | grep -q 'sandbox.*plugins/demo/tests/run.sh'" "$out"
rm "$demo/tests/run.sh"
printf 'touch "$HOME/setup-outside-the-sandbox"\n' >> "$flow_dispatcher"
out="$("$repo/tools/lint.sh" 2>/dev/null)"; code=$?
check "FlowDispatcherWithALineBesideTheDispatch_FailsLint: lint exits 1 and names the flow run.sh once it runs anything but the dispatch" sh -c "[ $code -eq 1 ] && printf '%s' \"\$0\" | grep -q 'flow dispatcher holds more than the dispatch.*plugins/flow/tests/run.sh'" "$out"

echo "lint holds ShellCheck and Ruff to the baseline"
python="$(command -v python3)"; linted="$work/linted"; linted_template="$work/linted-template"
mkdir -p "$linted_template/plugins/demo" "$linted_template/tools"; git init -q "$linted_template"
cp "$root/ruff.toml" "$root/.shellcheckrc" "$linted_template/"
printf '#!/bin/sh\nset -u\nprintf "%%s\\n" "$1"\n' > "$linted_template/plugins/demo/clean.sh"
printf 'import os\n\nprint(os.name)\n' > "$linted_template/plugins/demo/clean.py"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted_template" >/dev/null
fresh_linted() { rm -rf "$linted"; cp -R "$linted_template" "$linted"; }
baseline_check() { env -u CI "$@" "$python" -I "$root/tools/lib/lint_baseline.py" check "$linted" 2>&1; }
unquoted_substitution() { printf 'echo $(date)\n' >> "$linted/plugins/demo/clean.sh"; }
rule_code_pattern='SC[0-9]{4}|[EFIBS][0-9]{3,4}|SIM[0-9]{3}'
fails_naming() { [ "$1" -eq 1 ] && printf '%s' "$2" | grep -qF -- "$3" && printf '%s' "$2" | grep -qF -- "$4"; }
passes_without_finding() { [ "$1" -eq 0 ] && ! printf '%s' "$2" | grep -Eqw "$rule_code_pattern"; }
fresh_linted
out="$(baseline_check)"; code=$?
check "CleanTree_Passes: exit 0 and no rule named, because the baseline of a clean tree is empty" passes_without_finding "$code" "$out"
unquoted_substitution
out="$(baseline_check)"; code=$?
check "NewShellcheckFinding_FailsAndNamesFileAndRule: exit 1 and the file and rule of the unquoted substitution, because the baseline records none" \
  fails_naming "$code" "$out" SC2046 plugins/demo/clean.sh
fresh_linted
printf 'import sys\n' >> "$linted/plugins/demo/clean.py"
out="$(baseline_check)"; code=$?
check "NewRuffFinding_FailsAndNamesFileAndRule: exit 1 and the file and rule of the unused import, because the baseline records none" \
  fails_naming "$code" "$out" F401 plugins/demo/clean.py
fresh_linted
unquoted_substitution
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
printf '#!/bin/sh\n\n\nset -u\nprintf "%%s\\n" "$1"\necho $(date)\n' > "$linted/plugins/demo/clean.sh"
out="$(baseline_check)"; code=$?
check "RecordedFindingOnAnotherLine_Passes: exit 0 and no rule named, because the baseline counts a rule per file and not its line" passes_without_finding "$code" "$out"
unquoted_substitution
out="$(baseline_check)"; code=$?
check "AnotherFindingOfARecordedRule_Fails: exit 1 and the file and rule named, because a count above the baseline is new" \
  fails_naming "$code" "$out" SC2046 plugins/demo/clean.sh
fresh_linted
unquoted_substitution
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
printf '#!/bin/sh\nset -u\nprintf "%%s\\n" "$1"\n' > "$linted/plugins/demo/clean.sh"
out="$(baseline_check)"; code=$?
check "FixedFinding_Passes: exit 0 and no rule named as new, because fixing a finding must not fail lint" passes_without_finding "$code" "$out"
check "FixedFinding_PointsToUpdate: the output names the update command, because the baseline can then be lowered" \
  sh -c 'printf "%s" "$1" | grep -qw update' sh "$out"
path_with() {
  name="$1"; shift; rm -rf "$work/path-$name"; mkdir -p "$work/path-$name"
  for tool in git "$@"; do ln -s "$(command -v "$tool")" "$work/path-$name/$tool"; done
}
path_with no-linters
path_with only-ruff ruff
path_with only-shellcheck shellcheck
fresh_linted
out="$(baseline_check "PATH=$work/path-only-ruff")"; code=$?
check "MissingShellcheckLocally_NamesHowToInstallIt: the output names shellcheck and its install command, because a developer must know what to install" \
  sh -c 'printf "%s" "$1" | grep -q "brew install shellcheck"' sh "$out"
out="$(baseline_check "PATH=$work/path-only-shellcheck")"; code=$?
check "MissingRuffLocally_NamesHowToInstallIt: the output names ruff and the file that pins it, because a developer must know what to install" \
  sh -c 'printf "%s" "$1" | grep -q "pip install -r tools/requirements-lint.txt"' sh "$out"
out="$(baseline_check "PATH=$work/path-no-linters")"; code=$?
check "MissingToolsLocally_Pass: exit 0, because a developer without the tools is not blocked" [ "$code" -eq 0 ]
out="$(baseline_check "PATH=$work/path-only-ruff" CI=1)"; code=$?
check "MissingShellcheckInCi_Fails: exit 1 and shellcheck named, because CI must run the checks it promises" \
  sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -q shellcheck' sh "$code" "$out"
out="$(baseline_check "PATH=$work/path-only-shellcheck" CI=1)"; code=$?
check "MissingRuffInCi_Fails: exit 1 and ruff named, because CI must run the checks it promises" \
  sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -q ruff' sh "$code" "$out"
rewrite_python() { printf '%b' "$1" > "$linted/plugins/demo/clean.py"; }
python_finding_named() {
  fresh_linted; rewrite_python "$3"; out="$(baseline_check)"; code=$?
  check "$1: exit 1 and $2 named for the file, because the chosen rule family must fail a new finding" \
    fails_naming "$code" "$out" "$2" plugins/demo/clean.py
}
python_finding_named "NewPycodestyleErrorFinding_Fails" E711 'import os\n\nprint(os.name == None)\n'
python_finding_named "NewImportOrderFinding_Fails" I001 'import sys\nimport os\n\nprint(os.name, sys.argv)\n'
python_finding_named "NewBugbearFinding_Fails" B006 'import os\n\n\ndef collect(items=[]):\n    return items\n\n\nprint(os.name)\n'
python_finding_named "NewBanditFinding_Fails" S605 'import os\n\nos.system("true")\n'
python_finding_named "NewFileOpenedWithoutWithFinding_Fails" SIM115 'import os\n\nhandle = open("data")\nprint(handle, os.name)\n'
python_finding_passes() {
  fresh_linted; rewrite_python "$3"; out="$(baseline_check)"; code=$?
  check "$1: exit 0 and no rule named, because $2 are not turned on yet" passes_without_finding "$code" "$out"
}
python_finding_passes "UnannotatedFunction_Passes" "annotation rules" 'import os\n\n\ndef describe(name):\n    return os.name + name\n\n\nprint(describe("x"))\n'
python_finding_passes "LongLine_Passes" "formatting checks" "import os\n\nprint(os.name, \"$(printf 'x%.0s' $(seq 1 120))\")\n"
python_finding_passes "TrailingWhitespace_Passes" "formatting checks" 'import os\n\nprint(os.name) \n'
fresh_linted
printf '#!/bin/sh\necho $1\n' >> "$linted/plugins/demo/clean.sh"
out="$(baseline_check)"; code=$?
check "UnquotedVariable_Passes: exit 0 and no rule named, because ShellCheck runs at warning severity and above" passes_without_finding "$code" "$out"
fresh_linted
printf '[[ -n "$1" ]]\n' > "$linted/plugins/demo/no-shebang.sh"
out="$(baseline_check)"; code=$?
check "BashismInFileWithoutShebang_Fails: exit 1 and SC3010 named, because the config makes ShellCheck read it as POSIX sh" \
  fails_naming "$code" "$out" SC3010 plugins/demo/no-shebang.sh
fresh_linted
mkdir -p "$linted/plugins/demo/hooks/git"; printf '#!/bin/sh\necho $(date)\n' > "$linted/plugins/demo/hooks/git/pre-commit"
out="$(baseline_check)"; code=$?
check "NewFindingInGitHookWithoutExtension_Fails: exit 1 and the hook named, because a hook is shell without a .sh name" \
  fails_naming "$code" "$out" SC2046 plugins/demo/hooks/git/pre-commit
fresh_linted
unquoted_substitution
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
printf '#!/bin/sh\nset -u\nprintf "%%s\\n" "$1"\n' > "$linted/plugins/demo/clean.sh"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
unquoted_substitution
out="$(baseline_check)"; code=$?
check "FindingReturningAfterUpdate_Fails: exit 1 and the file named, because update lowers the baseline to what was fixed" \
  fails_naming "$code" "$out" SC2046 plugins/demo/clean.sh
fresh_linted
out="$("$python" -I "$root/tools/lib/lint_baseline.py" check "$work/no-such-folder" 2>&1)"; code=$?
check "CheckOnFolderWithoutConfig_Fails: a nonzero exit, because a mistyped root must not pass in silence" [ "$code" -ne 0 ]
printf 'plugins/demo/clean.sh\tSC2046\tmany\n' > "$linted/tools/lint-baseline/shellcheck.tsv"
out="$(baseline_check)"; code=$?
check "MalformedBaselineLine_Fails: exit 1 and the baseline file named, because a baseline that cannot be read must not pass" \
  fails_naming "$code" "$out" shellcheck.tsv shellcheck
baseline_lines_hold_file_rule_and_count='NF != 3 || $1 ~ /:/ || $2 !~ /^[A-Za-z]+[0-9]+$/ || $3 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }'
fresh_linted
unquoted_substitution
printf 'import sys\n' >> "$linted/plugins/demo/clean.py"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
check "UpdatedBaselineFiles_HoldFileRuleAndCountOnly: every line is a file, a rule code and a count, because a line number would break on any shift" \
  sh -c '[ -s "$2/shellcheck.tsv" ] && [ -s "$2/ruff.tsv" ] && awk -F "\t" "$1" "$2"/shellcheck.tsv "$2"/ruff.tsv' sh "$baseline_lines_hold_file_rule_and_count" "$linted/tools/lint-baseline"
check "CommittedBaselineFiles_HoldFileRuleAndCountOnly: the real baselines have no line numbers, because they must survive line shifts" \
  sh -c '[ -s "$2/shellcheck.tsv" ] && awk -F "\t" "$1" "$2"/shellcheck.tsv "$2"/ruff.tsv' sh "$baseline_lines_hold_file_rule_and_count" "$root/tools/lint-baseline"
fresh_linted
unquoted_substitution
printf 'greeting=hello\n' > "$linted/plugins/demo/settings.sh"
printf '#!/bin/sh\n# shellcheck source=plugins/demo/settings.sh\n. "$(dirname "$0")/settings.sh"\nprintf "%%s\\n" "$greeting"\n' > "$linted/plugins/demo/greet.sh"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" --shellcheck-chunks 1 >/dev/null
cp "$linted/tools/lint-baseline/shellcheck.tsv" "$work/one-chunk.tsv"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" --shellcheck-chunks 3 >/dev/null
check "ShellcheckBaselineFromThreeChunks_EqualsOneChunk: the same baseline file, because ShellCheck reports per file and follows a sourced file outside its own chunk" \
  sh -c '[ -s "$1" ] && cmp -s "$1" "$2"' sh "$work/one-chunk.tsv" "$linted/tools/lint-baseline/shellcheck.tsv"
fresh_linted
mkdir -p "$linted/tools/lib"; cp "$root/tools/lint.sh" "$linted/tools/"; cp "$root/tools/lib/lint_baseline.py" "$linted/tools/lib/"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
printf '#!/bin/sh\necho $(date)\n' > "$linted/plugins/demo/new-finding.sh"
printf 'import shutil\n' > "$linted/plugins/demo/new_finding.py"
out="$("$linted/tools/lint.sh" 2>/dev/null)"; code=$?
check "LintWithNewShellcheckFinding_FailsAndNamesFileAndRule: tools/lint.sh exits 1 naming the new script and SC2046, because lint runs the baseline check" \
  fails_naming "$code" "$out" SC2046 plugins/demo/new-finding.sh
check "LintWithNewRuffFinding_FailsAndNamesFileAndRule: tools/lint.sh exits 1 naming the new module and F401, because lint runs the baseline check" \
  fails_naming "$code" "$out" F401 plugins/demo/new_finding.py
check "LintOnTheCommittedTree_Passes: exit 0 and no rule named, because the committed baseline records today's findings" \
  passes_without_finding "$committed_tree_code" "$committed_tree_out"
real_ruff="$(command -v ruff)"; mkdir -p "$work/other-ruff"
printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "ruff 0.0.1"; exit 0; }\nexec "%s" "$@"\n' "$real_ruff" > "$work/other-ruff/ruff"; chmod +x "$work/other-ruff/ruff"
fresh_linted
cp "$root/tools/requirements-lint.txt" "$linted/tools/"
out="$(baseline_check "PATH=$work/other-ruff:$PATH")"; code=$?
check "RuffAtAnotherVersionLocally_NotesAndPasses: exit 0 and the installed version named, because a developer's version is a note and not a failure" \
  sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -qF 0.0.1' sh "$code" "$out"
out="$(baseline_check "PATH=$work/other-ruff:$PATH" CI=1)"; code=$?
check "RuffAtAnotherVersionInCi_Fails: exit 1 and the installed version named, because CI must run the pinned version the baseline came from" \
  sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qF 0.0.1' sh "$code" "$out"

echo "test.sh fails a part named on the command line that cannot run"
# The seed copies tracked and unignored files only, so it has no node_modules; node is a stub.
mkdir -p "$work/node-bin"; printf '#!/bin/sh\nexit 0\n' > "$work/node-bin/node"; chmod +x "$work/node-bin/node"
out="$(PATH="$work/node-bin:$PATH" "$seed/tools/test.sh" console-app 2>&1)"; code=$?
check "NamedConsoleAppWithoutDependencies_Fails: exits 1 and gives the command that installs them, because a skipped suite is no pass" \
  sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qF "cd plugins/console/app && npm ci && cd ui && npm ci"' sh "$code" "$out"
out="$(PATH="/usr/bin:/bin" "$seed/tools/test.sh" plugins 2>&1)"; code=$?
check "NamedPluginsWithoutClaudeCli_Fails: exits 1 and says the claude CLI is missing, because a skipped validation is no pass" \
  sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qF "plugins cannot run, the claude CLI missing"' sh "$code" "$out"

echo "the sandbox keeps a suite off the checkout it runs from"
# host stands in for the real checkout: a repo with one commit whose config the tests watch.
host="$work/host"
new_host() {
  rm -rf "$host"; git init -q -b main "$host"
  git -C "$host" -c user.email=h@h -c user.name=h commit -q --allow-empty -m init
}
host_config() { cat "$host/.git/config"; }
# A throwaway suite as every suite in this repo starts: its own temp folder, then the sandbox.
# Its body is $1; it runs from host, the way a suite runs from the checkout it tests.
sandboxed_suite() {
  printf '#!/bin/sh\nwork="$(mktemp -d)"\n. "%s/tools/lib/sandbox.sh"; sandbox_enter "$work" "%s"\ntrap '"'"'sandbox_close $?'"'"' EXIT\ncd "$work"\n%s\n' \
    "$root" "$host" "$1" > "$work/suite.sh"
  (cd "$host" && sh "$work/suite.sh" > "$work/suite.out" 2>&1)
}
new_host; before="$(host_config)"; rm -f "$work/ran"
# A subshell: sh keeps an assignment made in front of a function call after the call returns.
# The suite's last line leaves a marker, so a suite that never got that far fails too.
(GIT_DIR="$host/.git"; GIT_WORK_TREE="$host"; export GIT_DIR GIT_WORK_TREE
  sandboxed_suite "git init -q repo && git -C repo config user.email t@t && touch '$work/ran'")
check "SuiteWithGitDirExported_LeavesHostConfigUnchanged: the suite ran its git calls and the host config did not move" \
  sh -c '[ -f "$1" ] && [ "$2" = "$3" ]' sh "$work/ran" "$(host_config)" "$before"
new_host
sandboxed_suite 'git init -q repo && git -C repo config user.email t@t'; code=$?
check "SuiteThatStaysInItsTempFolder_Passes: a suite whose git calls stay in its temp folder exits 0" [ "$code" -eq 0 ]
new_host
sandboxed_suite "git config --file '$host/.git/config' core.bare true"; code=$?
check "SuiteThatMakesHostBare_Fails: a suite that sets core.bare on the checkout it runs from exits 1 with the sandbox's failure message" \
  sh -c '[ "$1" -eq 1 ] && grep -qF -- "$2" "$3"' sh "$code" "$sandbox_failure_message" "$work/suite.out"

echo "sandboxed.sh keeps a test command off the checkout it runs from"
new_host; before="$(host_config)"; rm -f "$work/ran"
(cd "$host" && GIT_DIR="$host/.git" GIT_WORK_TREE="$host" sh "$root/tools/lib/sandboxed.sh" "$host" \
  sh -c 'cd "$(mktemp -d)" && git init -q repo && git -C repo config user.email t@t && touch "$1"' sh "$work/ran" >/dev/null 2>&1)
check "TestCommandWithGitDirExported_LeavesHostConfigUnchanged: the command ran its git calls and the host config did not move" \
  sh -c '[ -f "$1" ] && [ "$2" = "$3" ]' sh "$work/ran" "$(host_config)" "$before"
new_host
(cd "$host" && sh "$root/tools/lib/sandboxed.sh" "$host" git config --file "$host/.git/config" core.bare true > "$work/command.out" 2>&1); code=$?
check "TestCommandThatMakesHostBare_Fails: a command that sets core.bare on the checkout it runs from exits 1 with the sandbox's failure message" \
  sh -c '[ "$1" -eq 1 ] && grep -qF -- "$2" "$3"' sh "$code" "$sandbox_failure_message" "$work/command.out"
new_host
printf 'tracked\n' > "$host/notes.txt"
git -C "$host" add notes.txt && git -C "$host" -c user.email=h@h -c user.name=h commit -q -m notes
printf 'owner edit\n' > "$host/notes.txt"
(cd "$host" && sh "$root/tools/lib/sandboxed.sh" "$host" sh -c 'printf "overwritten\n" > "$1"' sh "$host/notes.txt" > "$work/command.out" 2>&1); code=$?
check "TestCommandThatOverwritesModifiedWatchedFile_Fails: a command that rewrites a file the owner already modified exits 1 with the sandbox's failure message" \
  sh -c '[ "$1" -eq 1 ] && grep -qF -- "$2" "$3"' sh "$code" "$sandbox_failure_message" "$work/command.out"
new_host
printf 'tracked\n' > "$host/café notes.txt"
git -C "$host" add . && git -C "$host" -c user.email=h@h -c user.name=h commit -q -m notes
printf 'owner edit\n' > "$host/café notes.txt"
(cd "$host" && sh "$root/tools/lib/sandboxed.sh" "$host" sh -c 'printf "overwritten\n" > "$1"' sh "$host/café notes.txt" > "$work/command.out" 2>&1); code=$?
check "TestCommandThatOverwritesModifiedWatchedFileWithNonAsciiName_Fails: a command that rewrites a file the owner already modified, whose name has an accent and a space, exits 1 with the sandbox's failure message" \
  sh -c '[ "$1" -eq 1 ] && grep -qF -- "$2" "$3"' sh "$code" "$sandbox_failure_message" "$work/command.out"

[ "$fails" -eq 0 ] && echo "tools: ok"
exit $(( fails > 0 ))

#!/bin/sh
# Tests for the standards hooks. Builds a throwaway repo, feeds each hook a host payload and checks
# the exit code and the reason. Run from anywhere: hooks/tests/run.sh. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
hooks="$here/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# No test reaches the network, the desktop or a real agent. The owner's shell may export
# FLOW_SLACK_WEBHOOK, so it is cleared, and these tools are stubs that log to $work/offline.log.
# A test that needs one of them puts its own fake earlier in PATH.
unset FLOW_SLACK_WEBHOOK
mkdir -p "$work/offline"
for tool in curl wget gh osascript notify-send claude codex; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
fails=0
EXPECT_ENV=""
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

expect() {
  # $1 name, $2 hook, $3 command text, $4 expected exit, $5 expected stderr substring or empty
  payload="$(printf '{"tool_input":{"command":%s}}' "$(printf '%s' "$3" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')")"
  # shellcheck disable=SC2086
  err="$(printf '%s' "$payload" | env $EXPECT_ENV "$hooks/$2" 2>&1 >/dev/null)"; code=$?
  if [ "$code" -ne "$4" ]; then fail "$1 (exit $code, wanted $4): $err"; return; fi
  if [ -n "$5" ] && ! printf '%s' "$err" | grep -qF -- "$5"; then fail "$1 (missing '$5'): $err"; return; fi
  pass "$1"
}

cd "$work"
git init -q -b main repo && cd repo
git config user.email t@t && git config user.name t
mkdir -p .standards src/App .github/workflows
cat > .standards/config.json <<'JSON'
{
  "version": "0.1.0",
  "languages": [
    { "name": "csharp", "extensions": [".cs"],
      "format": [ { "prefix": "src/", "command": "sh -c 'for f in {files}; do grep -q TABS \"$f\" && exit 1; done; exit 0'" } ],
      "comments": { "line": "//", "doc": "///", "public": "public", "doc_inside": ["interface", "enum"], "allow_markers": ["float-boundary:"] } }
  ],
  "build": "true",
  "protected": [".editorconfig", "**/Directory.Build.props", ".github/workflows/**"]
}
JSON
printf 'class A {}\n' > src/App/A.cs
git add -A && git commit -qm init

echo "command detection"
expect "not a commit: echo"          check-no-verify.sh 'echo "git commit --no-verify"'   0 ""
expect "no-verify long flag"         check-no-verify.sh 'git commit --no-verify -m x'     2 "no-verify"
expect "no-verify short flag"        check-no-verify.sh 'git commit -nm x'                2 "no-verify"
expect "no-verify after cd"          check-no-verify.sh 'cd src && git commit -n -m x'    2 "no-verify"
expect "no-verify with -C"           check-no-verify.sh 'git -C /tmp commit -n -m x'      2 "no-verify"
expect "push no-verify"              check-no-verify.sh 'git push --no-verify'            2 "no-verify"
expect "plain commit passes"         check-no-verify.sh 'git commit -m x'                 0 ""
expect "grep for commit is no commit" check-no-verify.sh 'git log --grep commit -n 1'    0 ""

echo "protected config"
printf 'root = true\n' > .editorconfig; git add .editorconfig
expect "editorconfig blocked"        check-config.sh 'git commit -m "tweak"'              2 ".editorconfig"
expect "editorconfig with [config]"  check-config.sh 'git commit -m "build: [config] tweak"' 0 ""
git reset -q .editorconfig; rm .editorconfig
printf 'x\n' > .github/workflows/ci.yml; git add .github
expect "nested glob blocked"         check-config.sh 'git commit -m "ci"'                 2 "ci.yml"
git reset -q .github; rm -r .github
printf 'x\n' > src/Directory.Build.props; git add src/Directory.Build.props
expect "** prefix glob blocked"      check-config.sh 'git commit -m "props"'              2 "Directory.Build.props"
git reset -q src; rm src/Directory.Build.props

echo "comments"
printf 'class B {\n  // explains the code\n  int x;\n}\n' > src/App/B.cs; git add src/App/B.cs
expect "line comment blocked"        check-comments.sh 'git commit -m x'                  2 "B.cs:2"
expect "line comment with [why-comment]" check-comments.sh 'git commit -m "[why-comment] x"' 0 ""
printf 'class B {\n  // float-boundary: epsilon\n  int x;\n}\n' > src/App/B.cs; git add src/App/B.cs
expect "allowed marker passes"       check-comments.sh 'git commit -m x'                  0 ""
printf 'class B {\n  var u = "http://x";\n}\n' > src/App/B.cs; git add src/App/B.cs
expect "url is not a comment"        check-comments.sh 'git commit -m x'                  0 ""
printf 'public class C {\n  /// <summary>doc</summary>\n  public void Run() {}\n}\n' > src/App/C.cs; git add src/App/C.cs
expect "doc on public passes"        check-comments.sh 'git commit -m x'                  0 ""
printf 'public class C {\n  /// <summary>doc</summary>\n  void Run() {}\n}\n' > src/App/C.cs; git add src/App/C.cs
expect "doc on non-public blocked"   check-comments.sh 'git commit -m x'                  2 "C.cs:2"
expect "doc with [allow-docs]"       check-comments.sh 'git commit -m "[allow-docs] x"'   0 ""
printf 'public interface I {\n  /// <summary>doc</summary>\n  void Run();\n}\n' > src/App/C.cs; git add src/App/C.cs
expect "doc on an interface member passes" check-comments.sh 'git commit -m x'             0 ""
printf 'public enum E {\n  /// <summary>doc</summary>\n  One,\n  Two\n}\n' > src/App/C.cs; git add src/App/C.cs
expect "doc on an enum member passes"  check-comments.sh 'git commit -m x'                 0 ""
printf 'public class C {\n  /// <summary>doc</summary>\n  [Obsolete]\n  public void Run() {}\n}\n' > src/App/C.cs; git add src/App/C.cs
expect "attribute between doc and public passes" check-comments.sh 'git commit -m x'       0 ""
printf 'public class C {\n  /// <summary>doc</summary>\n  [Obsolete]\n  void Run() {}\n}\n' > src/App/C.cs; git add src/App/C.cs
expect "attribute between doc and private blocked" check-comments.sh 'git commit -m x'    2 "C.cs:2"
printf 'public class C {\n  public interface I {\n    /// <summary>doc</summary>\n    void Run();\n  }\n  /// <summary>doc</summary>\n  void Hidden() {}\n}\n' > src/App/C.cs; git add src/App/C.cs
expect "nested interface passes, sibling private member blocked" check-comments.sh 'git commit -m x' 2 "C.cs:6"
cp .standards/config.json "$work/config.bak"
printf 'public interface I {\n  /// <summary>doc</summary>\n  void Run();\n}\n' > src/App/C.cs; git add src/App/C.cs
sed 's/"doc_inside": \["interface", "enum"\], //' "$work/config.bak" > .standards/config.json
expect "no doc_inside key: interface and enum by default" check-comments.sh 'git commit -m x' 0 ""
sed 's/"doc_inside": \["interface", "enum"\]/"doc_inside": []/' "$work/config.bak" > .standards/config.json
expect "doc_inside []: interface member blocked" check-comments.sh 'git commit -m x'       2 "C.cs:2"
cp "$work/config.bak" .standards/config.json
git add -A; git commit -qm "fixture" >/dev/null
printf 'public class C {\n  /// <summary>doc</summary>\n  public void Run() {}\n}\n' > src/App/C.cs
expect "doc above unchanged public line (-a mode)" check-comments.sh 'git commit -am x'    0 ""
git checkout -q -- src/App/C.cs
printf 'class D {}\n' > src/App/D.cs; git add src/App/D.cs; git commit -qm "add D" >/dev/null
printf 'class D {\n  // note\n}\n' > src/App/D.cs
expect "unstaged change ignored without -a" check-comments.sh 'git commit -m x'           0 ""
expect "pathspec commit reads the working tree" check-comments.sh 'git commit -m x src/App/D.cs' 2 "D.cs:2"
git checkout -q -- src/App/D.cs

echo "format"
printf 'class E {\n\tTABS\n}\n' > src/App/E.cs; git add src/App/E.cs
expect "formatter failure blocks"    check-format.sh 'git commit -m x'                    2 "formatter"
git reset -q src/App/E.cs; rm src/App/E.cs
printf 'class F {}\n' > src/App/F.cs; git add src/App/F.cs
expect "formatter success passes"    check-format.sh 'git commit -m x'                    0 ""
mkdir -p other; printf 'TABS\n' > other/G.cs; git add other/G.cs
expect "file outside the prefix is not checked" check-format.sh 'git commit -m x'         0 ""
git reset -q .; rm -rf other src/App/F.cs

echo "project gates (config: gates)"
cp .standards/config.json "$work/config.bak"
python3 - <<'PY'
import json
c = json.load(open(".standards/config.json"))
c["gates"] = [
  {"name": "build", "command": "test -f gate-ok", "paths": ["src/**"], "when": ["commit", "ci"]},
  {"name": "local-only", "command": "test -f local-ok", "when": ["commit"]},
  {"name": "push-gate", "command": "test -f push-ok", "when": ["push"]},
  {"name": "pause", "forbid": ["update-golden", "update-hash-stream"], "marker": "[closeout #1]"}
]
json.dump(c, open(".standards/config.json", "w"), indent=2)
PY
printf 'class G {}\n' > src/App/G.cs; git add src/App/G.cs; touch local-ok
expect "command gate fails: blocked, named" check-gates.sh 'git commit -m x'            2 "gate build failed"
touch gate-ok
expect "command gate passes"         check-gates.sh 'git commit -m x'                    0 ""
rm gate-ok; git reset -q src/App/G.cs; rm src/App/G.cs
mkdir -p other; printf 'x\n' > other/note.txt; git add other/note.txt
expect "no file under the gate's paths: skipped" check-gates.sh 'git commit -m x'       0 ""
git reset -q other; rm -r other
expect "push gate blocks a push"     check-gates.sh 'git push origin main'               2 "gate push-gate failed"
touch push-ok
expect "push gate passes"            check-gates.sh 'git push'                           0 ""
rm push-ok
expect "forbidden command blocked"   check-gates.sh 'dotnet run -- update-golden x.json' 2 "gate pause"
expect "forbidden command with the marker in the command" check-gates.sh 'dotnet run -- update-golden x.json # [closeout #1]' 0 ""
printf '[closeout #1] regenerate\n' > "$work/msg"
expect "forbidden command with the marker in the -F message" check-gates.sh "git commit -F $work/msg && ./update-hash-stream" 0 ""
expect "plain command untouched"     check-gates.sh 'dotnet build'                       0 ""
expect "forbid: a quoted mention is no run" check-gates.sh 'echo "update-golden is paused" > note.txt' 0 ""
expect "forbid: a heredoc doc edit is no run" check-gates.sh "cat > docs/golden.md <<'EOF'
Never run update-golden without the owner.
EOF" 0 ""
expect "forbid: a commit message naming it is no run" check-gates.sh 'git commit -m "docs: update-golden is paused"' 0 ""
expect "forbid: a longer word is no run" check-gates.sh 'ls update-golden-all' 0 ""
expect "forbid: the script path runs it" check-gates.sh './tools/update-golden.sh' 2 "gate pause"
expect "forbid: bash -c runs it" check-gates.sh 'bash -c "update-golden x.json"' 2 "gate pause"
expect "forbid: after && runs it" check-gates.sh 'git add . && update-hash-stream' 2 "gate pause"
expect "forbid: a quoted one-word argument still runs it" check-gates.sh 'dotnet run -- "update-golden" x.json' 2 "gate pause"
expect "forbid: a quoted script path still runs it" check-gates.sh '"./tools/update-golden.sh"' 2 "gate pause"
expect "forbid: a one-word -m message is no run" check-gates.sh 'git commit -m "update-golden"' 0 ""
expect "forbid: a one-word grep pattern is no run" check-gates.sh 'grep -rn "update-golden" docs' 0 ""
printf 'class G {}\n' > src/App/G.cs; git add src/App/G.cs; touch gate-ok
EXPECT_ENV="STANDARDS_STAGE=ci"
expect "ci stage runs only the gates that list ci" check-gates.sh 'git commit -m x'     0 ""
rm gate-ok
expect "ci stage: the ci gate still blocks" check-gates.sh 'git commit -m x'            2 "gate build failed"
EXPECT_ENV=""
git reset -q src/App/G.cs; rm src/App/G.cs local-ok
cp "$work/config.bak" .standards/config.json

echo "command gates: marker and the commit message"
python3 - <<'PY'
import json
c = json.load(open(".standards/config.json"))
c["gates"] = [
  {"name": "golden", "command": "test -f golden-ok", "marker": "[closeout #2]"},
  {"name": "hand-edits", "command": "case \"$STANDARDS_COMMIT_MESSAGE\" in *hand-edit*) echo \"saw: $STANDARDS_COMMIT_MESSAGE\"; exit 1;; esac", "when": ["commit"]}
]
json.dump(c, open(".standards/config.json", "w"), indent=2)
PY
expect "marked command gate runs on a plain commit"   check-gates.sh 'git commit -m x'                     2 "gate golden failed"
expect "...and names the marker that lets it through" check-gates.sh 'git commit -m x'                    2 "add [closeout #2]"
expect "marked command gate skipped by the marker in -m" check-gates.sh 'git commit -m "[closeout #2] regenerate"' 0 ""
printf '[closeout #2] regenerate\n' > "$work/msg"
expect "marked command gate skipped by the marker in -F" check-gates.sh "git commit -F $work/msg"          0 ""
EXPECT_ENV="STANDARDS_GATES=unmarked"
expect "pre-commit mode leaves marked gates to commit-msg" check-gates.sh 'git commit -m x'                0 ""
EXPECT_ENV="STANDARDS_GATES=marked"
expect "commit-msg mode runs the marked gate"        check-gates.sh 'git commit -m x'                     2 "gate golden failed"
expect "commit-msg mode skips the unmarked gate"     check-gates.sh 'git commit -m "hand-edit hashes [closeout #2]"' 0 ""
EXPECT_ENV=""
touch golden-ok
expect "the gate command sees the commit message"    check-gates.sh 'git commit -m "hand-edit hashes"'    2 "saw: hand-edit hashes"
expect "...and passes on another message"            check-gates.sh 'git commit -m "tidy"'                0 ""
git reset -q; mv golden-ok golden-ok.off
printf 'x\n' > golden-pending; git add golden-pending
printf 'tidy\n' > "$work/msg"
if "$hooks/git/pre-commit" >/dev/null 2>&1; then pass "git pre-commit does not run the marked gate"; else fail "pre-commit blocked on a marked gate"; fi
if "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1; then fail "git commit-msg lets the marked gate through"; else pass "git commit-msg runs the marked gate"; fi
printf '[closeout #2] tidy\n' > "$work/msg"
if "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1; then pass "git commit-msg honours the marker"; else fail "git commit-msg ignored the gate marker"; fi
git reset -q golden-pending; mv golden-pending golden-pending.off; mv golden-pending.off "$work/"; mv golden-ok.off "$work/"
cp "$work/config.bak" .standards/config.json

echo "an agent's commit runs the gates once"
python3 - "$work/count.log" <<'PY'
import json, sys
c = json.load(open(".standards/config.json"))
c["gates"] = [{"name": "count", "command": "echo ran >> %s" % sys.argv[1]}]
json.dump(c, open(".standards/config.json", "w"), indent=2)
PY
: > "$work/count.log"
printf 'x\n' > once.txt; git add once.txt
expect "the agent hook runs the gate"                check-gates.sh 'git commit -m "add once"'            0 ""
printf 'add once\n' > "$work/msg"
"$hooks/git/pre-commit" >/dev/null 2>&1; "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1
check "git's hooks skip the gate the agent hook passed for the same index" [ "$(grep -c ran "$work/count.log")" = 1 ]
printf 'y\n' > twice.txt; git add twice.txt
"$hooks/git/pre-commit" >/dev/null 2>&1
check "a different index runs the gate again" [ "$(grep -c ran "$work/count.log")" = 2 ]
: > "$work/count.log"
expect "commit -a records nothing (the index will change)" check-gates.sh 'git commit -a -m x'          0 ""
"$hooks/git/pre-commit" >/dev/null 2>&1
check "...so git's hook runs the gate" [ "$(grep -c ran "$work/count.log")" = 2 ]
: > "$work/count.log"
"$hooks/git/pre-commit" >/dev/null 2>&1
check "a human commit with no agent record runs the gate" [ "$(grep -c ran "$work/count.log")" = 1 ]
git reset -q; mv once.txt twice.txt "$work/"
cp "$work/config.bak" .standards/config.json

echo "git hooks"
printf 'class H {\n  // bad\n}\n' > src/App/H.cs; git add src/App/H.cs
if "$hooks/git/pre-commit" >/dev/null 2>&1; then pass "pre-commit has no message, so it leaves the comment rule to commit-msg"; else fail "pre-commit blocked without a message"; fi
printf 'add H\n' > "$work/msg"
if "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1; then fail "commit-msg lets a bad comment through"; else pass "commit-msg blocks the comment"; fi
printf '[why-comment] add H\n' > "$work/msg"
if "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1; then pass "commit-msg sees the marker in the real message"; else fail "commit-msg ignored the marker"; fi
git reset -q src/App/H.cs; rm src/App/H.cs
printf 'class E {\n\tTABS\n}\n' > src/App/E.cs; git add src/App/E.cs
if "$hooks/git/pre-commit" >/dev/null 2>&1; then fail "pre-commit lets a format failure through"; else pass "pre-commit blocks on the formatter"; fi
git reset -q src/App/E.cs; rm src/App/E.cs
if "$hooks/git/pre-push" >/dev/null 2>&1; then pass "pre-push runs the build"; else fail "pre-push failed"; fi

echo "check-range: the gates per commit over a range"
mkdir -p "$work/range" && cp -R .standards "$work/range/" && cd "$work/range" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p src/App && printf 'class A {}\n' > src/App/A.cs && git add -A && git commit -qm base
base="$(git rev-parse HEAD)"
printf 'class B {}\n' > src/App/B.cs && git add -A && git commit -qm "clean"
printf 'class C {\n  // why\n}\n' > src/App/C.cs && git add -A && git commit -qm "[why-comment] explained"
out="$("$hooks/check-range.sh" "$base" HEAD 2>&1)"; code=$?
if [ "$code" -eq 0 ] && printf '%s' "$out" | grep -q '2 commit(s) checked'; then pass "clean range passes, each commit against its own message"; else fail "clean range: exit $code: $out"; fi
printf 'class D {\n  // bad\n}\n' > src/App/D.cs && git add -A && git commit -qm "unexplained"
printf 'class E {}\n' > src/App/E.cs && git add -A && git commit -qm "later clean"
out="$("$hooks/check-range.sh" "$base" HEAD 2>&1)"; code=$?
if [ "$code" -eq 1 ] && printf '%s' "$out" | grep -q 'in commit .* unexplained' && printf '%s' "$out" | grep -q 'D.cs:2'; then pass "bad commit named, later commit does not hide it"; else fail "bad range: exit $code: $out"; fi
if [ "$(git symbolic-ref -q --short HEAD)" = main ] && [ -z "$(git status --porcelain)" ]; then pass "checkout restored"; else fail "checkout not restored"; fi
printf 'dirty\n' >> src/App/A.cs
"$hooks/check-range.sh" "$base" HEAD >/dev/null 2>&1; code=$?
if [ "$code" -eq 2 ]; then pass "refuses to run over tracked changes"; else fail "ran over tracked changes (exit $code)"; fi
git checkout -q -- src/App/A.cs
cd "$work/repo"

echo "delivery gate"
gate() { printf '%s' "$1" | FLOW_HOME="$PWD/.flow" "$hooks/delivery-gate.sh" 2>/dev/null; }
out="$(gate '{}')"; [ -z "$out" ] && pass "no claim: no block" || fail "no claim blocked: $out"
mkdir -p .flow/reports/local-task-1 .flow/runs
printf '{"item":"local:task/1","step":"implement"}\n' > .flow/claim.json
out="$(gate '{}')"; [ -z "$out" ] && pass "claim without a run: no block" || fail "claim without a run blocked: $out"
printf '{"item":"local:task/1","step":"implement","reports":"%s/.flow/reports/local-task-1"}\n' "$PWD" > .flow/runs/local-task-1.json
out="$(gate '{}')"; printf '%s' "$out" | grep -q '"decision":"block"' && printf '%s' "$out" | grep -q 'implement.json' && pass "step in flight without a result blocks" || fail "no block for a missing result: $out"
out="$(gate '{"stop_hook_active":true}')"; [ -z "$out" ] && pass "stop_hook_active: no second block" || fail "stop_hook_active blocked: $out"
printf '{"status":"done","summary":"ok"}\n' > .flow/reports/local-task-1/implement.json
out="$(gate '{}')"; [ -z "$out" ] && pass "result written: no block" || fail "result written but blocked: $out"
printf '{"item":"local:task/1","step":"pr","reports":"%s/.flow/reports/local-task-1"}\n' "$PWD" > .flow/runs/local-task-1.json
printf '{"status":"done"}\n' > .flow/reports/local-task-1/pr.json
out="$(gate '{}')"; printf '%s' "$out" | grep -q 'No verify report' && pass "pr without a verify report blocks" || fail "pr without verify not blocked: $out"
printf '{"status":"fail","attempts":1,"checks":[{"name":"build","status":"pass","summary":"ok"},{"name":"tests","status":"fail","summary":"2 failed"}]}\n' > .flow/reports/local-task-1/verify.json
out="$(gate '{}')"; printf '%s' "$out" | grep -q 'tests: 2 failed' && pass "pr with a failing verify blocks with the failing check" || fail "pr with failing verify: $out"
printf '{"status":"fail","attempts":3,"checks":[]}\n' > .flow/reports/local-task-1/verify.json
out="$(gate '{}')"; [ -z "$out" ] && pass "third attempt escalates (no block)" || fail "third attempt blocked: $out"
printf '{"status":"pass","attempts":1,"checks":[]}\n' > .flow/reports/local-task-1/verify.json
out="$(gate '{}')"; [ -z "$out" ] && pass "passing verify: no block" || fail "passing verify blocked: $out"
rm -rf .flow

echo "json fallback without jq"
orig_path="$PATH"
if command -v jq >/dev/null 2>&1; then
  nojq="$work/nojq"; mkdir -p "$nojq"
  for dir in $(printf '%s' "$PATH" | tr ':' ' '); do
    for bin in "$dir"/*; do
      name="$(basename "$bin")"
      [ "$name" = "jq" ] && continue
      [ -e "$nojq/$name" ] || ln -s "$bin" "$nojq/$name" 2>/dev/null
    done
  done
  PATH="$nojq"; export PATH
  command -v jq >/dev/null 2>&1 && fail "jq still on PATH"
fi
expect "no-verify without jq" check-no-verify.sh 'git commit -n -m x' 2 "no-verify"

echo "init: stamp, guard, session-start nudge (on a copy of the plugin, so the plugin can change)"
PATH="$orig_path"; export PATH
plugin_copy="$work/plugin"; cp -R "$hooks/.." "$plugin_copy"; rm -rf "$plugin_copy/evals/results"
init="$plugin_copy/skills/init/scripts/init.sh"; start="$plugin_copy/hooks/session-start.sh"
mkdir -p "$work/empty" && cd "$work/empty" && git init -q -b main && git config user.email t@t && git config user.name t
check "init: an empty repo installs and lists the gaps" sh -c "'$init' | grep -q 'Gaps' && '$init' | grep -q 'build is empty' && '$init' | grep -q 'languages is empty' && '$init' | grep -q 'testing-guide.md: 4 placeholder'"
check "init: --check flags the gaps (exit 1)" sh -c "! '$init' --check >/dev/null && '$init' --check | grep -q 'gap: .standards/config.json: test is empty'"
mkdir -p "$work/fresh" && cd "$work/fresh" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p src/App && printf 'Microsoft Visual Studio Solution File\n' > src/App.sln && printf 'class A {}\n' > src/App/A.cs
check "init: a fresh install writes the stamp" sh -c "'$init' >/dev/null && grep -q '^source	' .standards/stamp && grep -q '	.standards/rules/' .standards/stamp"
check "init: detected commands leave only the guide placeholders as gaps" sh -c "'$init' --check | grep -c 'gap:' | grep -qx 1 && '$init' --check | grep -q 'gap: .standards/testing-guide.md: 4 placeholder'"
python3 -c 'import re,sys; p=".standards/testing-guide.md"; open(p,"w").write(re.sub(r"_fill in[^_]*_", "done", open(p).read()))'
check "init: writes only under .standards and the host paths" sh -c "[ ! -d docs ] && [ ! -d .githooks ] && [ -f .standards/testing-guide.md ] && [ -f .standards/rules/csharp.md ]"
check "init: no .githooks, hooksPath is the plugin folder" sh -c "[ \"\$(git config core.hooksPath)\" = .standards/hooks/git ]"
check "init: --check is clean after install" sh -c "'$init' --check | grep -q 'up to date'"
check "session-start: silent when the stamp matches" sh -c "[ -z \"\$(echo '{}' | '$start')\" ]"
printf '# mine\n' >> .codex/agents/standards-reviewer.toml
check "init: --check names a hand edit" sh -c "'$init' --check | grep -q 'edited by hand: .codex/agents/standards-reviewer.toml'"
check "init: refuses to replace a hand edit (exit 1, file kept)" sh -c "! '$init' | grep -q 'refused: .codex/agents/standards-reviewer.toml' || grep -q '# mine' .codex/agents/standards-reviewer.toml && ! '$init' >/dev/null"
check "init: --force replaces it" sh -c "'$init' --force >/dev/null && ! grep -q '# mine' .codex/agents/standards-reviewer.toml && '$init' --check | grep -q 'up to date'"
printf '\n- X-99 A new rule.\n' >> "$plugin_copy/rules/common/$(ls "$plugin_copy/rules/common" | head -1)"
check "session-start: nudges when the plugin changed" sh -c "echo '{}' | '$start' | grep -q 'behind standards v' && echo '{}' | '$start' | grep -q 'drift: .standards/rules/'"
check "init: refresh brings the stamp back in step" sh -c "'$init' >/dev/null && [ -z \"\$(echo '{}' | '$start')\" ]"
rm .standards/stamp
check "session-start: no stamp asks for one init" sh -c "echo '{}' | '$start' | grep -q 'no install stamp'"
"$init" >/dev/null
check "init: a settings file that runs the gates again is reported as stale" sh -c "mkdir -p .claude && printf '{\"hooks\":{\"PreToolUse\":[{\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"sh .standards/hooks/check-comments.sh\"}]}]}}\n' > .claude/settings.json && '$init' --check | grep -q 'stale: .claude/settings.json runs check-comments.sh' && rm .claude/settings.json"
check "init: notes the missing project-scope enablement on both hosts" sh -c "'$init' --check | grep -q 'Claude does not enable the plugin' && '$init' --check | grep -q 'Codex does not enable the plugin'"
check "init: quiet about enablement once the hosts list the plugin" sh -c "mkdir -p .claude .codex && printf '{\"enabledPlugins\":{\"standards@brain-plugins\":true}}\n' > .claude/settings.json && printf '[plugins.\"standards@brain-plugins\"]\nenabled = true\n' > .codex/config.toml && ! '$init' --check | grep -q 'does not enable the plugin'"

echo "init: project links and roster (config: project)"
mkdir -p AI/agents/skills/physics AI/rules AI/agents/briefs
printf -- '---\nname: physics\ndescription: x\n---\n' > AI/agents/skills/physics/SKILL.md
printf -- '---\npaths:\n  - "src/**"\n---\nrule\n' > AI/rules/sim.md
printf '# physics-reviewer\n\nReview the physics.\n' > AI/agents/briefs/physics-reviewer.md
cat > AI/agents/roster.json <<'JSON'
{ "agents": {
  "physics-reviewer": { "plugin": "project", "step": "review", "tier": "read-only", "model": "opus", "effort": "high",
    "paths": ["src/Physics/**"], "description": "Reviews the physics.", "brief": "AI/agents/briefs/physics-reviewer.md", "skills": ["physics"] } } }
JSON
python3 - <<'PY'
import json
c = json.load(open(".standards/config.json"))
c["project"] = {"skills": "AI/agents/skills", "rules": "AI/rules", "roster": "AI/agents/roster.json"}
json.dump(c, open(".standards/config.json", "w"), indent=2)
PY
check "init --check: links and agents are drift before the run" sh -c "'$init' --check | grep -q 'drift: .claude/skills -> ../AI/agents/skills' && '$init' --check | grep -q 'drift: .claude/agents/physics-reviewer.md'"
check "init: links point at the project folders, relative" sh -c "'$init' >/dev/null && [ \"\$(readlink .claude/skills)\" = ../AI/agents/skills ] && [ \"\$(readlink .agents/skills)\" = ../AI/agents/skills ] && [ \"\$(readlink .claude/rules/project)\" = ../../AI/rules ] && [ -f .claude/skills/physics/SKILL.md ]"
check "init: roster rendered for both hosts with the plugin defaults" sh -c "grep -q '^model: opus' .claude/agents/physics-reviewer.md && grep -q '^tools: Read, Grep' .claude/agents/physics-reviewer.md && grep -q '^  - physics' .claude/agents/physics-reviewer.md && grep -q 'Review the physics' .claude/agents/physics-reviewer.md && grep -q 'model = \"gpt-6-sol\"' .codex/agents/physics-reviewer.toml && grep -q 'sandbox_mode = \"read-only\"' .codex/agents/physics-reviewer.toml"
check "init: --check is clean after the run" sh -c "'$init' --check | grep -q 'up to date'"
printf 'More.\n' >> AI/agents/briefs/physics-reviewer.md
check "init --check: an edited brief makes the rendered agents stale" sh -c "'$init' --check | grep -q 'drift: .claude/agents/physics-reviewer.md' && '$init' --check | grep -q 'drift: .codex/agents/physics-reviewer.toml'"
check "init: re-render picks the edit up" sh -c "'$init' >/dev/null && grep -q 'More.' .codex/agents/physics-reviewer.toml"
rm .claude/skills && ln -s /nowhere .claude/skills
check "init: a link pointing elsewhere is fixed" sh -c "'$init' >/dev/null && [ \"\$(readlink .claude/skills)\" = ../AI/agents/skills ]"
printf '{ "agents": {} }\n' > AI/agents/roster.json
check "init: an agent dropped from the roster is removed" sh -c "'$init' | grep -q 'physics-reviewer.md removed' && [ ! -f .claude/agents/physics-reviewer.md ] && [ ! -f .codex/agents/physics-reviewer.toml ]"
mkdir -p "$work/plain" && cd "$work/plain" && git init -q
check "session-start: silent in a project without the standards" sh -c "[ -z \"\$(echo '{}' | '$start')\" ]"

echo "init: upgrade from the docs/ layout (v0.1.0), project with its own .githooks"
mkdir -p "$work/old" && cd "$work/old" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p docs/standards .githooks .standards
cp "$plugin_copy"/rules/common/*.md "$plugin_copy"/rules/csharp.md docs/standards/
printf '# my edit\n' >> docs/standards/csharp.md
sed 's/{{test}}/true/; s/{{mutation}}/x/' "$plugin_copy/templates/testing-guide.md" > docs/testing-guide.md; printf 'my fixtures\n' >> docs/testing-guide.md
printf '#!/bin/sh\necho mine\n' > .githooks/pre-commit; chmod +x .githooks/pre-commit
printf '{"version":"0.1.0","languages":[],"build":"","test":"true","protected":[]}\n' > .standards/config.json
check "init --check: old docs/ copies are stale" sh -c "'$init' --check | grep -q 'stale: docs/standards/01-design.md' && '$init' --check | grep -q 'stale: docs/testing-guide.md'"
check "init: unchanged old rule copies removed, edited one kept and reported" sh -c "'$init' | grep -q 'docs/standards/csharp.md is not what init wrote' && [ ! -f docs/standards/01-design.md ] && [ -f docs/standards/csharp.md ]"
check "init: old guide moved with its edits" sh -c "[ ! -f docs/testing-guide.md ] && grep -q 'my fixtures' .standards/testing-guide.md"
check "init: project .githooks kept, one call appended, hooksPath .githooks" sh -c "grep -q 'echo mine' .githooks/pre-commit && [ \"\$(grep -c standards/hooks/git/pre-commit .githooks/pre-commit)\" = 1 ] && [ -f .githooks/pre-push ] && [ \"\$(git config core.hooksPath)\" = .githooks ]"
check "init: commit-msg written with the message file passed on" sh -c "[ -x .githooks/commit-msg ] && grep -q 'standards/hooks/git/commit-msg\" \"\\\$@\"' .githooks/commit-msg"
check "init: second run appends nothing more" sh -c "'$init' >/dev/null; [ \"\$(grep -c standards/hooks/git/pre-commit .githooks/pre-commit)\" = 1 ]"

echo "init: a project hook that ends in exit"
mkdir -p "$work/exits" && cd "$work/exits" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p .githooks .standards
printf '#!/bin/sh\necho mine\nexit 0\n' > .githooks/pre-commit
printf '#!/bin/sh\necho mine\nexit 0\n"$(git rev-parse --show-toplevel)/.standards/hooks/git/commit-msg" "$@" || exit 1  # standards plugin\n' > .githooks/commit-msg
printf '#!/bin/sh\nset -e\necho mine\nexit\n' > .githooks/pre-push
chmod +x .githooks/*
printf '{"version":"0.1.0","languages":[],"build":"true","test":"true","protected":[]}\n' > .standards/config.json
check "init --check: a call after an exit is drift" sh -c "'$init' --check | grep -q 'commit-msg: the standards call is after an exit'"
check "init --check: a missing call is drift" sh -c "'$init' --check | grep -q 'pre-commit lacks the standards call'"
"$init" >/dev/null
before_exit='index($0, n) { c = NR } /^exit/ { e = NR } END { exit !(c && e && c < e) }'
check "init: the call goes before a trailing exit 0" sh -c "tail -1 .githooks/pre-commit | grep -qx 'exit 0' && awk -v n=standards/hooks/git/pre-commit '$before_exit' .githooks/pre-commit"
check "init: a bare exit stays last, call before it" sh -c "tail -1 .githooks/pre-push | grep -qx 'exit' && awk -v n=standards/hooks/git/pre-push '$before_exit' .githooks/pre-push"
check "init: a stranded call moves up, once" sh -c "[ \"\$(grep -c standards/hooks/git/commit-msg .githooks/commit-msg)\" = 1 ] && awk -v n=standards/hooks/git/commit-msg '$before_exit' .githooks/commit-msg"
check "init: the user's own lines stay" sh -c "grep -q 'echo mine' .githooks/pre-commit && grep -q 'set -e' .githooks/pre-push"
cp .githooks/pre-commit "$work/pc.after"
"$init" >/dev/null
check "init: a second run changes nothing" sh -c "cmp -s .githooks/pre-commit '$work/pc.after' && ! '$init' --check | grep -q 'githooks'"

[ "$fails" -eq 0 ] && echo "hooks: ok" || { echo "hooks: $fails failed"; exit 1; }

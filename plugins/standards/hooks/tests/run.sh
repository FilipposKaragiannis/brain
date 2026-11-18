#!/bin/sh
# Tests for the standards hooks. Builds a throwaway repo, feeds each hook a host payload and checks
# the exit code and the reason. Run from anywhere: hooks/tests/run.sh. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
hooks="$here/.."
work="$(mktemp -d)"
. "$hooks/../../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$hooks/.."
trap 'sandbox_close $?' EXIT
# No test reaches the network, the desktop or a real agent: these tools are stubs that log to
# $work/offline.log. A test that needs one of them puts its own fake earlier in PATH.
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
printf 'chore: regenerate [closeout #1]\n' > "$work/msg"
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
printf 'chore: regenerate [closeout #2]\n' > "$work/msg"
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
printf 'chore: tidy\n' > "$work/msg"
if "$hooks/git/pre-commit" >/dev/null 2>&1; then pass "git pre-commit does not run the marked gate"; else fail "pre-commit blocked on a marked gate"; fi
if "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1; then fail "git commit-msg lets the marked gate through"; else pass "git commit-msg runs the marked gate"; fi
printf 'chore: tidy [closeout #2]\n' > "$work/msg"
if "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1; then pass "git commit-msg honours the marker"; else fail "git commit-msg ignored the gate marker"; fi
git reset -q golden-pending; mv golden-pending golden-pending.off; mv golden-pending.off "$work/"; mv golden-ok.off "$work/"
cp "$work/config.bak" .standards/config.json

echo "command gates: git's repository variables (tests/gate-git-env.sh)"
sh "$here/gate-git-env.sh" > "$work/gate-git-env.out" 2>&1; code=$?
check "GateGitEnvSuite_Passes: every check in gate-git-env.sh passed ($(tail -n 1 "$work/gate-git-env.out"))" [ "$code" -eq 0 ]
[ "$code" -eq 0 ] || grep '^  FAIL' "$work/gate-git-env.out"

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
printf 'chore: add once\n' > "$work/msg"
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

echo "commit subject (W-01)"
subject_case() {
  # $1 name, $2 message, $3 expected exit
  printf '%s\n' "$2" > "$work/subject"
  "$hooks/check-subject.sh" "$work/subject" >/dev/null 2>&1; code=$?
  [ "$code" -eq "$3" ] && pass "$1" || fail "$1 (exit $code, wanted $3)"
}
subject_case "a conventional subject passes"            'feat(bots): a back rod lifts over a slow ball' 0
subject_case "a subject without a scope passes"         'docs: record the decision' 0
subject_case "a breaking-change bang passes"            'refactor(api)!: drop the old verb' 0
subject_case "a gate instruction as subject is blocked" 'Approve the plan and re-bless the tables' 2
subject_case "an unknown type is blocked"               'update(bots): something' 2
subject_case "a missing space after the colon is blocked" 'fix(bots):nospace' 2
subject_case "a merge subject passes"                   "Merge branch 'main' into flow/gh-1" 0
subject_case "a fixup subject passes"                   'fixup! feat(bots): x' 0
printf '# a git comment line\n\nfix(x): after the comment\n' > "$work/subject"
check "git comment lines before the subject are skipped" "$hooks/check-subject.sh" "$work/subject"
printf 'not conventional\n' > "$work/msg"
if "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1; then fail "git commit-msg lets a bad subject through"; else pass "git commit-msg blocks a bad subject"; fi

echo "git hooks"
printf 'class H {\n  // bad\n}\n' > src/App/H.cs; git add src/App/H.cs
if "$hooks/git/pre-commit" >/dev/null 2>&1; then pass "pre-commit has no message, so it leaves the comment rule to commit-msg"; else fail "pre-commit blocked without a message"; fi
printf 'chore: add H\n' > "$work/msg"
if "$hooks/git/commit-msg" "$work/msg" >/dev/null 2>&1; then fail "commit-msg lets a bad comment through"; else pass "commit-msg blocks the comment"; fi
printf 'chore: add H [why-comment]\n' > "$work/msg"
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
check "init: no project roster, no eval runner" sh -c "[ ! -e .standards/evals ]"
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
check "init: roster rendered for both hosts with the plugin defaults" sh -c "grep -q '^model: opus' .claude/agents/physics-reviewer.md && grep -q '^tools: Read, Grep' .claude/agents/physics-reviewer.md && grep -q '^  - physics' .claude/agents/physics-reviewer.md && grep -q 'Review the physics' .claude/agents/physics-reviewer.md && grep -q 'model = \"gpt-6.1-sol\"' .codex/agents/physics-reviewer.toml && grep -q 'sandbox_mode = \"read-only\"' .codex/agents/physics-reviewer.toml"
check "init: --check is clean after the run" sh -c "'$init' --check | grep -q 'up to date'"
check "init: a roster installs the eval runner and ignores its results" sh -c "[ -x .standards/evals/run.sh ] && grep -qx 'results/' .standards/evals/.gitignore && grep -q '	.standards/evals/run.sh' .standards/stamp"
check "evals: no project.evals prints the hint and exits 0 without claude" sh -c ".standards/evals/run.sh | grep -q 'Set project.evals' && ! grep -q 'plugin eval' '$work/offline.log' 2>/dev/null"
# A fake claude records what the runner hands it: the flags, the wrapper's manifest and agents,
# and the copied cases with the repo's path beside them (the scaffold scripts depend on it).
mkdir -p "$work/evalbin" "$work/evallog" AI/agents/evals/case-a AI/agents/evals/results/old
printf 'name: case-a\n' > AI/agents/evals/case-a/case.yaml
cat > "$work/evalbin/claude" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "$work/evallog/args"
printf '%s\n' "\$3" > "$work/evallog/dir"
cat "\$3/.claude-plugin/plugin.json" > "$work/evallog/manifest"
ls "\$3/agents" > "$work/evallog/agents"
[ ! -L "\$3/cases" ] && [ -f "\$3/cases/case-a/case.yaml" ] && cat "\$3/cases/.repo-root" > "$work/evallog/top"
[ -e "\$3/cases/results" ] && echo yes > "$work/evallog/results"
command -v git > "$work/evallog/git"
exit 3
EOF
chmod +x "$work/evalbin/claude"
python3 -c 'import json; p = ".standards/config.json"; c = json.load(open(p)); c["project"]["evals"] = "AI/agents/evals"; json.dump(c, open(p, "w"), indent=2)'
PATH="$work/evalbin:$PATH" .standards/evals/run.sh --case 'case-*' >/dev/null 2>&1; eval_status=$?
check "evals: the runner keeps the eval's exit status" [ "$eval_status" = 3 ]
check "evals: the runner passes the flags, then the caller's" grep -q '^plugin eval .* --scaffold --allow-tools Bash Read Glob Grep Agent --trust-plugin --no-publish --ablation none --judge-model sonnet --output-dir .standards/evals/results/[0-9-]* --case case-\*$' "$work/evallog/args"
check "evals: the wrapper is named after the repo and reads its cases from cases/" sh -c "grep -q '\"name\": \"fresh\"' '$work/evallog/manifest' && grep -q '\"evals\": \"cases\"' '$work/evallog/manifest'"
check "evals: the wrapper carries copies of the rendered agents" grep -qx physics-reviewer.md "$work/evallog/agents"
check "evals: the cases are a copy that names this repo in .repo-root" sh -c "[ \"\$(cat '$work/evallog/top')\" = \"\$(pwd -P)\" ]"
check "evals: old results stay out of the copy" [ ! -e "$work/evallog/results" ]
check "evals: the wrapper is removed after the run" sh -c "[ ! -e \"\$(cat '$work/evallog/dir')\" ]"
if real_git="$(xcrun --find git 2>/dev/null)"; then
  check "evals: git runs through a wrapper that calls the real binary" sh -c "[ \"\$(cat '$work/evallog/git')\" = \"\$(pwd)/.standards/evals/.bin/git\" ] && grep -q '$real_git' .standards/evals/.bin/git"
else
  check "evals: without xcrun git is left alone" sh -c "[ ! -e .standards/evals/.bin/git ]"
fi
check "evals: the wrappers are git-ignored" grep -qx '.bin/' .standards/evals/.gitignore
printf 'More.\n' >> AI/agents/briefs/physics-reviewer.md
check "init --check: an edited brief makes the rendered agents stale" sh -c "'$init' --check | grep -q 'drift: .claude/agents/physics-reviewer.md' && '$init' --check | grep -q 'drift: .codex/agents/physics-reviewer.toml'"
check "init: re-render picks the edit up" sh -c "'$init' >/dev/null && grep -q 'More.' .codex/agents/physics-reviewer.toml"
rm .claude/skills && ln -s /nowhere .claude/skills
check "init: a link pointing elsewhere is fixed" sh -c "'$init' >/dev/null && [ \"\$(readlink .claude/skills)\" = ../AI/agents/skills ]"
printf '{ "agents": {} }\n' > AI/agents/roster.json
check "init: an agent dropped from the roster is removed" sh -c "'$init' | grep -q 'physics-reviewer.md removed' && [ ! -f .claude/agents/physics-reviewer.md ] && [ ! -f .codex/agents/physics-reviewer.toml ]"
check "init: an empty roster keeps the eval runner" [ -x .standards/evals/run.sh ]
python3 -c 'import json; p = ".standards/config.json"; c = json.load(open(p)); c["project"]["roster"] = ""; json.dump(c, open(p, "w"), indent=2)'
check "init --check: the runner is stale once the roster goes" sh -c "'$init' --check | grep -q 'stale: .standards/evals/run.sh (no project roster)'"
check "init: the runner goes with the roster" sh -c "'$init' | grep -q 'run.sh removed' && [ ! -e .standards/evals ] && '$init' --check | grep -q 'up to date'"
mkdir -p "$work/plain" && cd "$work/plain" && git init -q
check "session-start: silent in a project without the standards" sh -c "[ -z \"\$(echo '{}' | '$start')\" ]"

echo "init: a project waives and demotes rules (config: rules.relaxed, rules.judgement)"
mkdir -p "$work/relaxed" && cd "$work/relaxed" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p .standards
printf '{"version":"0.1.0","languages":[{"name":"sh","extensions":[".sh"],"format":[{"prefix":"","command":"true"}]}],"build":"true","test":"true","protected":[],"rules":{"relaxed":["D-11","S-09"],"judgement":["M-06"]}}\n' > .standards/config.json
"$init" >/dev/null
python3 -c 'import re,sys; p=".standards/testing-guide.md"; open(p,"w").write(re.sub(r"_fill in[^_]*_", "done", open(p).read()))'
hard_rules="sed -n '/^## Hard rules/,/^## Signals/p' AGENTS.md"
waived_rules="sed -n '/^## Waived by this project/,/^\$/p' AGENTS.md"
check "init: a waived rule leaves the block's hard rules, its neighbour stays" sh -c "! $hard_rules | grep -q '^- D-11 ' && $hard_rules | grep -q '^- D-10 '"
check "init: the block lists every waived rule under Waived by this project" sh -c "$waived_rules | grep -q '^- D-11 ' && $waived_rules | grep -q '^- S-09 '"
check "init: a waived rule leaves the Claude rule copy, D-10 and D-12 stay" sh -c "! grep -qF '**D-11 ' .claude/rules/standards-design.md && grep -qF '**D-10 ' .claude/rules/standards-design.md && grep -qF '**D-12 ' .claude/rules/standards-design.md"
check "init: a waived rule leaves the full rule text, D-10 and D-12 stay" sh -c "! grep -qF '**D-11 ' .standards/rules/01-design.md && grep -qF '**D-10 ' .standards/rules/01-design.md && grep -qF '**D-12 ' .standards/rules/01-design.md"
check "init: --check is clean right after a relaxed install" sh -c "'$init' --check | grep -q 'up to date'"
demoted_rule="grep -F '**M-06 ' .claude/rules/standards-methods.md"
judgement_rules="sed -n '/^## Judgement in this project/,/^\$/p' AGENTS.md"
check "init: a demoted rule is tagged judgement, relaxed from hard, in the Claude rule copy" sh -c "$demoted_rule | grep -qF '[judgement, relaxed from hard by this project]'"
check "init: a demoted rule loses its hard tag in the Claude rule copy" sh -c "$demoted_rule && ! $demoted_rule | grep -qF '[hard]'"
check "init: the block lists a demoted rule under Judgement in this project" sh -c "$judgement_rules | grep -q '^- M-06 '"
check "init: a demoted rule leaves the block's hard rules" sh -c "$hard_rules | grep -q '^- M-05 ' && ! $hard_rules | grep -q '^- M-06 '"
printf '# mine\n' >> .claude/rules/standards-design.md
check "init: --check names a hand edit to a relaxed rule copy" sh -c "'$init' --check | grep -q 'edited by hand: .claude/rules/standards-design.md'"
"$init" --force >/dev/null
python3 -c 'import json; p = ".standards/config.json"; c = json.load(open(p)); del c["rules"]; json.dump(c, open(p, "w"), indent=2)'
check "init: dropping the list replaces the relaxed copy with the waived rule back" sh -c "! '$init' | grep -q 'refused' && grep -qF '**D-11 ' .claude/rules/standards-design.md"
check "init: --check is clean once the list is gone" sh -c "'$init' --check | grep -q 'up to date'"
printf '{"version":"0.1.0","languages":[{"name":"sh","extensions":[".sh"],"format":[{"prefix":"","command":"true"}]}],"build":"true","test":"true","protected":[],"rules":{"relaxed":["N-01","D-01"],"judgement":["M-01"]}}\n' > .standards/config.json
"$init" >/dev/null
signal_rules="sed -n '/^## Signals/,/^## /p' AGENTS.md"
check "init: a waived signal leaves the block's signals, its neighbour stays" sh -c "! $signal_rules | grep -q '^- N-01 ' && $signal_rules | grep -q '^- N-02 '"
check "init: a demoted signal is tagged judgement, relaxed from signal, in the Claude rule copy" sh -c "grep -F '**M-01 ' .claude/rules/standards-methods.md | grep -qF '[judgement, relaxed from signal by this project]'"
check "init: a waived judgement rule leaves the Claude rule copy" sh -c "! grep -qF '**D-01 ' .claude/rules/standards-design.md && grep -qF '**D-02 ' .claude/rules/standards-design.md"
check "init: --check is clean with a waived judgement rule and a demoted signal" sh -c "'$init' --check | grep -q 'up to date'"
printf '{"version":"0.1.0","languages":[{"name":"sh","extensions":[".sh"],"format":[{"prefix":"","command":"true"}]}],"build":"true","test":"true","protected":[],"rules":{"relaxed":["D-11"],"judgement":["D-11"]}}\n' > .standards/config.json
check "init: --check names an id in both lists as a gap" sh -c "'$init' --check | grep -q 'gap: .standards/config.json: rules.* D-11 '"
printf '{"version":"0.1.0","languages":[{"name":"sh","extensions":[".sh"],"format":[{"prefix":"","command":"true"}]}],"build":"true","test":"true","protected":[],"rules":{"judgement":["D-01"]}}\n' > .standards/config.json
check "init: --check names a demoted rule that is already judgement as a gap" sh -c "'$init' --check | grep -q 'gap: .standards/config.json: rules.judgement names D-01'"
printf '{"version":"0.1.0","languages":[{"name":"sh","extensions":[".sh"],"format":[{"prefix":"","command":"true"}]}],"build":"true","test":"true","protected":[],"rules":{"relaxed":["X-99"]}}\n' > .standards/config.json
check "init: --check fails on a waived id that is not a rule" sh -c "! '$init' --check"
check "init: --check names the waived id that is not a rule as a gap" sh -c "'$init' --check | grep -q 'gap: .standards/config.json: rules.relaxed names X-99'"
printf '{"version":"0.1.0","languages":[{"name":"sh","extensions":[".sh"],"format":[{"prefix":"","command":"true"}]}],"build":"true","test":"true","protected":[],"rules":{"judgement":["U-02"]}}\n' > .standards/config.json
check "init: --check names a demoted usage rule as a gap" sh -c "'$init' --check | grep -q 'gap: .standards/config.json: rules.judgement names U-02'"
printf '{"version":"0.1.0","languages":[{"name":"sh","extensions":[".sh"],"format":[{"prefix":"","command":"true"}]}],"build":"true","test":"true","protected":[],"rules":{"relaxed":["C-01"],"judgement":["W-01"]}}\n' > .standards/config.json
"$init" >/dev/null
check "init: --check names a waived rule a plugin hook enforces as a gap, with the hook" sh -c "'$init' --check | grep -q 'gap: .standards/config.json: rules.relaxed names C-01, which the plugin hook hooks/check-comments.sh enforces'"
check "init: --check names a demoted rule a plugin hook enforces as a gap, with the hook" sh -c "'$init' --check | grep -q 'gap: .standards/config.json: rules.judgement names W-01, which the plugin hook hooks/check-subject.sh enforces'"
check "init: a relaxed rule a plugin hook enforces stays in the block's hard rules" sh -c "$hard_rules | grep -q '^- C-01 ' && $hard_rules | grep -q '^- W-01 '"
check "init: a relaxed rule a plugin hook enforces is listed as neither waived nor demoted" sh -c "! sed -n '/^## Waived by this project/,/^## Code Review Rules/p' AGENTS.md | grep -qE '^- (C-01|W-01) '"
check "init: a new config carries empty relaxed and judgement lists" python3 -c "import json, sys; sys.exit(json.load(open('$work/fresh/.standards/config.json')).get('rules') != {'relaxed': [], 'judgement': []})"
check "init: without a rules key the block is the plugin's block, byte for byte" sh -c "sed -n '/^<!-- standards:begin/,/^<!-- standards:end/p' '$work/fresh/AGENTS.md' | sed '1d;\$d' | cmp -s - '$plugin_copy/rules/block.md'"

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

echo "init: a live hook in .git/hooks keeps core.hooksPath unset"
mkdir -p "$work/live-hooks" && cd "$work/live-hooks" && git init -q -b main && git config user.email t@t && git config user.name t
printf '#!/bin/sh\ngit lfs pre-push "$@"\n' > .git/hooks/pre-push; chmod +x .git/hooks/pre-push
"$init" > "$work/live-hooks.init.out" 2>&1
check "LiveHookInGitHooks_HooksPathStaysUnset: init leaves core.hooksPath unset so git still runs .git/hooks/pre-push" sh -c "[ -z \"\$(git config core.hooksPath)\" ]"
check "LiveHookInGitHooks_InitNamesTheHook: init names the live hook it would have bypassed" grep -q 'init: .git/hooks holds pre-push;' "$work/live-hooks.init.out"
git config --unset core.hooksPath
"$init" --check > "$work/live-hooks.check.out" 2>&1
check "LiveHookInGitHooks_CheckReportsNoHooksPathDrift: init --check does not count the unset core.hooksPath as drift" sh -c "[ -s '$work/live-hooks.check.out' ] && ! grep -q 'core.hooksPath is unset' '$work/live-hooks.check.out'"

echo "init: machine scope puts the block, the rules and the agents in the user folders, and wires the clone's hooks"
CLAUDE_CONFIG_DIR="$work/claude home"; CODEX_HOME="$work/codex"; export CLAUDE_CONFIG_DIR CODEX_HOME
owner_line="the owner's own instructions"; usage_error_status=2; blocks_per_user_file=1
mkdir -p "$CLAUDE_CONFIG_DIR" && printf '%s\n' "$owner_line" > "$CLAUDE_CONFIG_DIR/CLAUDE.md"
machine_config='{"version":"0.1.0","languages":[{"name":"shell","extensions":[".sh"],"format":[{"prefix":"","command":"true"}]}],"build":"true","test":"true","protected":[]}'
mkdir -p "$work/machine" && cd "$work/machine" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p docs .githooks .standards
printf '# Instructions\n' > docs/INSTRUCTIONS.md && ln -s docs/INSTRUCTIONS.md AGENTS.md && printf 'AGENTS.md\n' > .gitignore
printf '#!/bin/sh\necho mine\n' > .githooks/pre-commit && chmod +x .githooks/pre-commit
git add docs .gitignore .githooks && git commit -q -m 'chore: tracked instructions and hooks'
lfs_line='git lfs pre-push "$@"'
printf '#!/bin/sh\n%s\n' "$lfs_line" > .git/hooks/pre-push && chmod +x .git/hooks/pre-push
printf '%s\n' "$machine_config" > .standards/config.json
"$init" --scope project-wide > "$work/machine.bad-scope.out" 2>&1; bad_scope_status=$?
check "UnknownScope_InitExitsWithUsageError: a --scope value other than machine or project stops init with exit 2" [ "$bad_scope_status" = "$usage_error_status" ]
"$init" --scope machine > "$work/machine.init.out" 2>&1
check "MachineScope_TrackedFilesUnchanged: init --scope machine runs to its stamp and changes no tracked file" sh -c "[ -f .standards/stamp ] && git diff --quiet HEAD"
check "MachineScope_UserClaudeFileHoldsOneBlock: the user CLAUDE.md under \$work holds exactly one standards block" sh -c "[ \"\$(grep -c 'standards:begin' '$CLAUDE_CONFIG_DIR/CLAUDE.md')\" = $blocks_per_user_file ]"
check "MachineScope_UserCodexFileHoldsOneBlock: the user AGENTS.md under \$work holds exactly one standards block" sh -c "[ \"\$(grep -c 'standards:begin' '$CODEX_HOME/AGENTS.md')\" = $blocks_per_user_file ]"
check "MachineScope_OwnerTextKeptAboveBlock: the owner's line in the user CLAUDE.md survives the install" grep -qxF "$owner_line" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
check "MachineScope_RulesInUserClaudeFolder: the Claude rules land in the user rules folder under \$work" test -f "$CLAUDE_CONFIG_DIR/rules/standards-design.md"
check "MachineScope_AgentsInUserCodexFolder: the Codex agents land in the user agents folder under \$work" test -f "$CODEX_HOME/agents/standards-reviewer.toml"
check "MachineScope_NoRulesInProjectFolder: machine scope writes no Claude rule into the project" sh -c "! ls .claude/rules/standards-* >/dev/null 2>&1"
check "MachineScope_HooksPathNeverSet: machine scope leaves core.hooksPath unset so git runs the clone's own hooks" sh -c "[ -z \"\$(git config core.hooksPath)\" ]"
check "MachineScope_ExistingPrePushLineRunsFirst: the standards call in .git/hooks/pre-push comes after the line already there" \
  awk -v existing="$lfs_line" -v needle=.standards/hooks/git/pre-push '$0 == existing { existing_line = NR } index($0, needle) { call_line = NR } END { exit !(existing_line && call_line > existing_line) }' .git/hooks/pre-push
check "MachineScope_MissingHookCreatedExecutable: a hook the clone lacked is created executable with the standards call" \
  sh -c "[ -x .git/hooks/commit-msg ] && grep -qF .standards/hooks/git/commit-msg .git/hooks/commit-msg"
check "MachineScope_TrackedGithooksUntouched: the tracked .githooks/pre-commit keeps its committed text" git diff --quiet HEAD -- .githooks/pre-commit
check "MachineScope_OutputsExcluded: git status lists none of the files machine scope wrote in the clone" sh -c "[ -z \"\$(git status --porcelain --untracked-files=all)\" ]"
wired_files="hooks/pre-commit hooks/commit-msg hooks/pre-push info/exclude"
mkdir -p "$work/machine.before"
for wired_file in $wired_files; do cp ".git/$wired_file" "$work/machine.before/${wired_file##*/}"; done
"$init" >/dev/null 2>&1
check "MachineScope_SecondRunChangesNothing: a second init leaves the clone's hook files and its exclude byte-equal" sh -c "
  for wired_file in $wired_files; do cmp -s \".git/\$wired_file\" \"$work/machine.before/\${wired_file##*/}\" || exit 1; done"
python3 -c 'import re,sys; p=".standards/testing-guide.md"; open(p,"w").write(re.sub(r"_fill in[^_]*_", "done", open(p).read()))'
"$init" --check > "$work/machine.check.out" 2>&1
check "MachineScope_CheckWithoutFlagIsClean: init --check, with no --scope, finds the machine install up to date" grep -q 'up to date' "$work/machine.check.out"
gate_ran="$work/machine.gate-ran"
python3 -c 'import json, sys
config = json.load(open(".standards/config.json"))
config["gates"] = [{"name": "marker", "command": "echo ran > \"%s\"" % sys.argv[1], "when": ["commit"]}]
json.dump(config, open(".standards/config.json", "w"))' "$gate_ran"
printf 'note\n' > note.txt && git add note.txt && git commit -q -m 'docs: add a note' >/dev/null 2>&1
check "MachineScope_CommitRunsTheHook: a commit in the clone runs the standards pre-commit and its project gate" test -f "$gate_ran"
mkdir -p "$work/machine-second" && cd "$work/machine-second" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p .standards && printf '%s\n' "$machine_config" > .standards/config.json
"$init" --scope machine >/dev/null 2>&1
cd "$work/machine"
"$init" --check > "$work/machine.second-check.out" 2>&1
check "SecondProjectSameHome_CheckStaysClean: a second project installed on the same user folders leaves the first one's --check up to date" grep -q 'up to date' "$work/machine.second-check.out"

echo "init: machine scope links .standards into the linked worktrees and flow's worktree_setup"
linked_worktree="$work/machine-wt"; flow_worktree="$work/machine-wt-flow"; flow_items_wanted=1
git worktree add -q "$linked_worktree" 2>/dev/null
mkdir -p .flow && printf 'pool:\nworktree_setup:\n  # - dotnet restore\ngates:\n' > .flow/config.yaml
"$init" >/dev/null 2>&1
"$init" >/dev/null 2>&1
check "LinkedWorktree_SeesTheConfig: the linked worktree reads the main worktree's config through .standards" test -f "$linked_worktree/.standards/config.json"
check "LinkedWorktree_StatusStaysClean: git status in the linked worktree lists nothing init wrote" sh -c "[ -z \"\$(git -C '$linked_worktree' status --porcelain --untracked-files=all)\" ]"
check "FlowConfig_WorktreeSetupGetsOneLine: two inits leave one item that links .standards under worktree_setup" \
  sh -c "[ \"\$(grep -c 'ln -s .*\\.standards' .flow/config.yaml)\" = $flow_items_wanted ]"
(cd "$linked_worktree" && "$init" --check > "$work/machine-wt.check.out" 2>&1)
check "LinkedWorktree_CheckIsClean: init --check run in the linked worktree finds the install up to date" grep -q 'up to date' "$work/machine-wt.check.out"
rm -f "$gate_ran"
(cd "$linked_worktree" && printf 'linked\n' > linked.txt && git add linked.txt && git commit -q -m 'docs: add a linked note' >/dev/null 2>&1)
check "LinkedWorktree_CommitRunsTheHook: a commit in the linked worktree runs the standards pre-commit and its project gate" test -f "$gate_ran"
git worktree add -q "$flow_worktree" 2>/dev/null
flow_setup_line="$(sed -n 's/^  - \(\[ -e \.standards \] .*\)$/\1/p' .flow/config.yaml)"
(cd "$flow_worktree" && sh -c "$flow_setup_line")
check "FlowSetupLine_LinksANewWorktree: the worktree_setup line, run in a new worktree, links its .standards to the main one" \
  sh -c '[ -n "$1" ] && [ -L "$2/.standards" ] && [ -f "$2/.standards/config.json" ]' sh "$flow_setup_line" "$flow_worktree"
check "MachineScope_RepeatedInits_UserFileKeepsOneBlock: after every init above, the user CLAUDE.md still holds exactly one standards block" \
  sh -c "[ \"\$(grep -c 'standards:begin' '$CLAUDE_CONFIG_DIR/CLAUDE.md')\" = $blocks_per_user_file ]"
grep -vF .standards/hooks/git/pre-push .git/hooks/pre-push > "$work/pre-push.stripped"; cat "$work/pre-push.stripped" > .git/hooks/pre-push
"$init" --check > "$work/machine.stripped-call.out" 2>&1
check "MachineScope_StrippedHookCall_CheckReportsDrift: init --check names the clone's pre-push once its standards call is gone" \
  grep -q '^init: drift: .*pre-push' "$work/machine.stripped-call.out"
"$init" >/dev/null 2>&1
exclude_file="$(git rev-parse --git-common-dir)/info/exclude"
sed '/^# standards:begin/,/^# standards:end/d' "$exclude_file" > "$work/exclude.stripped"; cat "$work/exclude.stripped" > "$exclude_file"
"$init" --check > "$work/machine.stripped-exclude.out" 2>&1
check "MachineScope_RemovedExcludeBlock_CheckReportsDrift: init --check names the exclude file once its standards block is gone" \
  grep -q '^init: drift: .*exclude' "$work/machine.stripped-exclude.out"
"$init" >/dev/null 2>&1
rm "$linked_worktree/.standards"
"$init" --check > "$work/machine.missing-link.out" 2>&1
check "LinkedWorktree_MissingLink_CheckReportsDrift: init --check names the linked worktree that lost its .standards link" \
  grep -q '^init: drift: .*/machine-wt/\.standards is missing' "$work/machine.missing-link.out"
"$init" >/dev/null 2>&1
git worktree remove --force "$linked_worktree"; git worktree remove --force "$flow_worktree"

echo "init: the standards call keeps the status of the hook lines before it"
mkdir -p "$work/failing-hooks" && cd "$work/failing-hooks" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p .standards && printf '%s\n' "$machine_config" > .standards/config.json
printf '#!/bin/sh\nfalse\n' > .git/hooks/pre-push
printf '#!/bin/sh\nfalse\nexit $?\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-push .git/hooks/pre-commit
"$init" --scope machine >/dev/null 2>&1
check "ClonePrePushEndingInFalse_StillFailsAfterMachineInit: the pre-push exits non-zero once init chained the standards call" \
  sh -c '! .git/hooks/pre-push origin url </dev/null'
check "ClonePreCommitEndingInExitStatus_StillFailsAfterMachineInit: exit \$? after a failing line still exits non-zero once init chained the standards call" \
  sh -c '! .git/hooks/pre-commit'
mkdir -p "$work/failing-githooks" && cd "$work/failing-githooks" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p .standards .githooks && printf '%s\n' "$machine_config" > .standards/config.json
printf '#!/bin/sh\nfalse\n' > .githooks/pre-push && chmod +x .githooks/pre-push
"$init" >/dev/null 2>&1
check "ProjectPrePushEndingInFalse_StillFailsAfterInit: the tracked .githooks/pre-push exits non-zero once init chained the standards call" \
  sh -c '! .githooks/pre-push origin url </dev/null'

echo "init: machine scope in a clone whose team set core.hooksPath"
mkdir -p "$work/team-hooks" && cd "$work/team-hooks" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p .githooks .standards
printf '#!/bin/sh\necho team\n' > .githooks/pre-commit && chmod +x .githooks/pre-commit
git add .githooks && git commit -q -m 'chore: team hooks' && git config core.hooksPath .githooks
printf '%s\n' "$machine_config" > .standards/config.json
"$init" --scope machine > "$work/team-hooks.init.out" 2>&1
check "TeamHooksPathSet_MachineScopeKeepsTheTeamPath: machine scope leaves the team's core.hooksPath as it was" \
  sh -c "[ \"\$(git config core.hooksPath)\" = .githooks ]"
check "TeamHooksPathSet_TrackedHooksUntouched: machine scope adds no call to the team's tracked hooks" git diff --quiet HEAD -- .githooks
check "TeamHooksPathSet_InitPrintsTheCallToAdd: init shows the hook call the owner adds by hand" grep -qF .standards/hooks/git/pre-commit "$work/team-hooks.init.out"
python3 -c 'import re,sys; p=".standards/testing-guide.md"; open(p,"w").write(re.sub(r"_fill in[^_]*_", "done", open(p).read()))'
"$init" --check > "$work/team-hooks.check.out" 2>&1
check "TeamHooksPathSet_CheckIsClean: init --check counts the hand-wired team hooks as no drift" grep -q 'up to date' "$work/team-hooks.check.out"
unset CLAUDE_CONFIG_DIR CODEX_HOME

[ "$fails" -eq 0 ] && echo "hooks: ok" || { echo "hooks: $fails failed"; exit 1; }

#!/bin/sh
# suite-parity.sh: tools/lib/suite_parity.py proves that no check is lost when a test runner is
# cut into suite files. Small hand-made logs under fixtures/flow-parity/hand stand for the old
# runner (a section header then result lines, with one child run and its wrapper line) and for
# the new one (every line prefixed with its suite); each way a move can go wrong is made from them
# and must fail by name. The real flow baseline inventory must load and compare clean with itself.
# Exit 0 when every check passes, 1 on any failure. test.sh runs it with the tools part.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

parity="$root/tools/lib/suite_parity.py"
hand="$here/fixtures/flow-parity/hand"
flow_parity="$here/fixtures/flow-parity"
parity_tool() { python3 -I "$parity" "$@"; }

old_inventory="$work/old.json"
parity_tool inventory --shape old --log "$hand/old.log" --headers "$hand/old-sections.txt" \
  --child "beta=$hand/beta.out" --output "$old_inventory"

# compare_candidate <log>: the inventory of a new-shape log compared with the old one; output in
# $work/compare.out and the exit status in $compare_code.
compare_candidate() {
  parity_tool inventory --shape new --log "$1" --output "$work/candidate.json"
  parity_tool compare --baseline "$old_inventory" --candidate "$work/candidate.json" \
    --mapping "${2:-$hand/mapping.json}" > "$work/compare.out" 2>&1
  compare_code=$?
}
allowed_with_reason() { [ "$compare_code" -eq 0 ] && reports "$1"; }
reports() { grep -qF -- "$1" "$work/compare.out"; }
fails_naming() { # fails_naming <report text>...: the compare failed and its report holds every text
  [ "$compare_code" -eq 1 ] || return 1
  for named in "$@"; do reports "$named" || return 1; done
}

echo "inventory of an old-shape log"
check "InventoryOfAStrayLine_KeepsTheSectionOpen: an error line that is no listed header must not start a section" \
  grep -qF '"unit": "alpha", "name": "Alpha_Two: the second check"' "$old_inventory"
check "InventoryOfARepeatedName_CountsIt: a name printed twice is one entry of count two" \
  grep -qF '"name": "a repeated check", "outcome": "ok", "count": 2' "$old_inventory"
check "InventoryOfAChildRun_KeepsTheChildResults: the wrapper hides them in the old log" \
  grep -qF '"kind": "child", "unit": "beta", "name": "Beta_One: the first beta check"' "$old_inventory"
awk '{ printf "test\tRun tools/test.sh\t2026-11-21T20:13:01.3747849Z %s\n", $0 }' "$hand/old.log" > "$work/old-ci.log"
parity_tool inventory --shape old --log "$work/old-ci.log" --headers "$hand/old-sections.txt" \
  --child "beta=$hand/beta.out" --output "$work/old-ci.json"
check "InventoryOfAGitHubLog_EqualsTheInventoryOfThePlainLog: the job, step and time prefix is framing, not a name" \
  cmp "$old_inventory" "$work/old-ci.json"

echo "compare: a move that keeps every check"
compare_candidate "$hand/new-same.log"
check "CompareOfAnIdenticalMove_ExitsZero: every check is where the mapping says" [ "$compare_code" -eq 0 ]
check "CompareOfAnIdenticalMove_CountsNoWrapperLine: seven old results less the wrapper make six checks" \
  reports "parity: ok, 6 checks in 2 suites, 1 wrapper lines mapped and not counted"

echo "compare: a move that goes wrong"
grep -v 'Alpha_Two' "$hand/new-same.log" > "$work/lost.log"
compare_candidate "$work/lost.log"
check "CompareOfALostCheck_Fails: a check that vanished is the loss the tool exists to catch" [ "$compare_code" -eq 1 ]
check "CompareOfALostCheck_NamesIt: the report says which check and in which suite" \
  reports "loss: core: Alpha_Two: the second check"
{ cat "$hand/new-same.log"; echo "[core]   ok   Extra_Check: new"; } > "$work/added.log"
compare_candidate "$work/added.log"
check "CompareOfAnAddedCheck_FailsAndNamesIt: an unexplained new check is a difference" \
  fails_naming "addition: core: Extra_Check: new"

{ cat "$hand/new-same.log"; echo "[core]   ok   Alpha_One: the first check"; } > "$work/duplicate.log"
compare_candidate "$work/duplicate.log"
check "CompareOfADuplicatedCheck_FailsAndNamesIt: a name that runs twice now ran once before" \
  fails_naming "duplicate: core: Alpha_One: the first check (baseline 1, candidate 2)"

sed 's/Alpha_Two/Alpha_2/' "$hand/new-same.log" > "$work/renamed.log"
compare_candidate "$work/renamed.log"
check "CompareOfARenamedCheck_NamesTheLossAndTheAddition: a rename is both the old name gone and a new name" \
  fails_naming "loss: core: Alpha_Two: the second check" "addition: core: Alpha_2: the second check"

sed 's/^\[core\]   ok   Alpha_Two/[beta]   ok   Alpha_Two/' "$hand/new-same.log" > "$work/moved.log"
compare_candidate "$work/moved.log"
check "CompareOfACheckInTheWrongSuite_FailsAndNamesBothSuites: the mapping puts it in core, the candidate in beta" \
  fails_naming "moved: beta: Alpha_Two: the second check (from suite core)"

awk '/a repeated check/ && !dropped { dropped = 1; next } { print }' "$hand/new-same.log" > "$work/once.log"
compare_candidate "$work/once.log"
check "CompareOfARepeatedNameRunOnceLess_FailsByCount: names compare as multisets, so two becoming one is a loss" \
  fails_naming "loss: core: a repeated check (baseline 2, candidate 1)"

{ cat "$hand/new-same.log"; echo "[beta]   skip Beta_One: the first beta check"; } > "$work/skipped.log"
compare_candidate "$work/skipped.log"
check "CompareOfANewSkip_FailsAndNamesIt: a check that now skips proves nothing" \
  fails_naming "skip: beta: Beta_One: the first beta check"

grep -v '^\[beta\]   ok' "$hand/new-same.log" > "$work/no-beta.log"
compare_candidate "$work/no-beta.log"
check "CompareOfACandidateWithoutASuite_NamesEveryLostCheck: both of beta's checks are gone" \
  fails_naming "loss: beta: Beta_One" "loss: beta: Beta_Two"

printf '{"sections": {}, "children": {"beta": "beta"}, "wrappers": [{"section": "beta (tests/beta.sh)", "name_prefix": "beta: ", "child": "beta"}]}\n' > "$work/unrouted.json"
compare_candidate "$hand/new-same.log" "$work/unrouted.json"
check "CompareWithASectionTheMappingDoesNotRoute_FailsAndNamesIt: a baseline section with no new suite is lost work" \
  fails_naming "unmapped: alpha"

printf '{"sections": {"alpha": "core"}, "children": {"beta": "beta"}, "wrappers": []}\n' > "$work/no-wrapper.json"
compare_candidate "$hand/new-same.log" "$work/no-wrapper.json"
check "CompareWithAWrapperLineTheMappingDoesNotName_FailsAsAnUnmappedSection: an unnamed wrapper line would count as a check the new suites lack" \
  fails_naming "unmapped: beta (tests/beta.sh)"

echo "compare: a difference the mapping explains"
printf '{"sections": {"alpha": "core"}, "children": {"beta": "beta"}, "wrappers": [{"section": "beta (tests/beta.sh)", "name_prefix": "beta: ", "child": "beta"}], "allowances": [{"kind": "loss", "suite": "core", "name": "Alpha_Two: the second check", "reason": "the check was a copy of the first"}]}\n' > "$work/allowance.json"
compare_candidate "$work/lost.log" "$work/allowance.json"
check "CompareOfALossTheMappingAllows_ExitsZeroAndSaysWhy: the move meant to drop it, with the reason on record" \
  allowed_with_reason "the check was a copy of the first"
compare_candidate "$hand/new-same.log" "$work/allowance.json"
check "CompareWithAnAllowanceThatMatchesNothing_Fails: a stale allowance would hide a later loss" \
  fails_naming "stale: core: Alpha_Two: the second check"

echo "the flow baseline"
baseline="$flow_parity/baseline-inventory.json"
parity_tool compare --baseline "$baseline" --candidate "$baseline" --mapping "$flow_parity/mapping-unmoved.json" > "$work/baseline.out" 2>&1
baseline_code=$?
check "CompareOfTheFlowBaselineWithItself_ExitsZero: the inventory loads and every unit has a route" [ "$baseline_code" -eq 0 ]
check "CompareOfTheFlowBaselineWithItself_MapsTheNineteenWrapperLines: one for each child run the old runner started" \
  grep -qF " 19 wrapper lines mapped and not counted" "$work/baseline.out"
check "CompareOfTheFlowBaselineWithItself_StatesTheTotals: 1489 inline and 1043 child checks in 60 sections and 19 child suites" \
  grep -qF "parity: ok, 2532 checks in 79 suites" "$work/baseline.out"
check "CompareOfTheFlowBaselineWithItself_CountsOnlyRealInlineChecks: 1508 inline result lines less 19 wrapper lines leave 1489" \
  python3 -I -c 'import json, sys; e = json.load(open(sys.argv[1]))["entries"]; sys.exit(0 if sum(x["count"] for x in e if x["kind"] == "section") - 19 == 1489 else 1)' "$baseline"
check "CompareOfTheFlowBaselineWithItself_CountsTheChildChecks: the 19 child runs hold 1043 results" \
  python3 -I -c 'import json, sys; e = json.load(open(sys.argv[1]))["entries"]; sys.exit(0 if sum(x["count"] for x in e if x["kind"] == "child") == 1043 else 1)' "$baseline"
python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); d["entries"] = [x for x in d["entries"] if x["unit"] != "adapter-contract-local"]; json.dump(d, open(sys.argv[2], "w"))' "$baseline" "$work/baseline-less-child.json"
parity_tool compare --baseline "$baseline" --candidate "$work/baseline-less-child.json" --mapping "$flow_parity/mapping-unmoved.json" > "$work/baseline-less-child.out" 2>&1
check "CompareOfTheFlowBaselineWithoutAChildRun_FailsAndNamesTheLoss: the checks a wrapper line hides are still checks" \
  grep -qF "loss: adapter-contract-local" "$work/baseline-less-child.out"
check "BaselineDefects_RecordsTheWorktreeRemoveLine: the known defect at run.sh line 3881 is written down, not fixed" \
  grep -qF "run.sh line 3881" "$flow_parity/baseline-defects.txt"
check "Help_ListsEveryNormalisation: a reader sees which variable text the tool removes before comparing" \
  sh -c 'python3 -I "$1" --help | grep -qF "Normalisation"' sh "$parity"

if [ "$fails" -eq 0 ]; then echo "suite-parity: ok"; else echo "suite-parity: $fails failed"; exit 1; fi

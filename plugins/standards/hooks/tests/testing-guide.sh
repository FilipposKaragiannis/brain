#!/bin/sh
# testing-guide.sh: the testing guide template's levels table names a slot for every row, and init
# keeps a guide filled from the older three-column template. Installs on a throwaway project from
# a copy of the plugin. Exit 0 when every check passes, 1 on any failure. tools/test.sh runs it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
hooks="$here/.."
work="$(mktemp -d)"
. "$hooks/../../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$hooks/.."
trap 'sandbox_close $?' EXIT
mkdir -p "$work/offline"
for tool in curl wget gh osascript notify-send claude codex; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

echo "init: a guide filled from the three-column template"
plugin_copy="$work/plugin"; cp -R "$hooks/.." "$plugin_copy"; rm -rf "$plugin_copy/evals/results"
init="$plugin_copy/skills/init/scripts/init.sh"
mkdir -p "$work/fresh" && cd "$work/fresh" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir -p src/App && printf 'Microsoft Visual Studio Solution File\n' > src/App.sln && printf 'class A {}\n' > src/App/A.cs
"$init" > "$work/fresh.init.out" 2>&1
cat > .standards/testing-guide.md <<'GUIDE'
# Testing guide

## Levels and commands

| level | when | command |
|---|---|---|
| unit | every change | `dotnet test` |
| integration | a boundary is crossed | `dotnet test --filter Category=Integration` |
| regression | every bug fix, named after the bug | part of the unit run |
| mutation | on PRs for changed files | `dotnet stryker` |

## Fixtures and helpers

- Where fixtures live and how to add one: tests/Fixtures.
GUIDE
check "ThreeColumnGuideFilled_CheckIsClean: init --check finds a guide filled from the three-column template up to date, with no gap" "$init" --check
"$init" > "$work/three-column.init.out" 2>&1; three_column_init_status=$?
check "ThreeColumnGuideFilled_InitRunsWithoutError: init exits 0 on a project whose guide was filled from the three-column template" [ "$three_column_init_status" -eq 0 ]
check "ThreeColumnGuideFilled_InitKeepsTheOwnersGuide: init leaves the owner's filled guide as written" grep -qF 'tests/Fixtures' .standards/testing-guide.md

echo "testing guide template: the levels table"
template_rows="$work/template-rows.tsv"; template_slots="$work/template-slots.txt"
python3 - "$hooks/../templates/testing-guide.md" "$template_rows" "$template_slots" <<'PARSE'
import sys
guide_text = open(sys.argv[1]).read()
levels_section = guide_text.split("## Levels and commands", 1)[1].split("\n## ", 1)[0]
header_cells = None
with open(sys.argv[2], "w") as rows_file:
    for line in levels_section.splitlines():
        if not line.startswith("|") or set(line) <= set("|-"):
            continue
        cells = [cell.strip() for cell in line.strip("|").split("|")]
        if header_cells is None:
            header_cells = cells
            continue
        row = dict(zip(header_cells, cells))
        slot_cell = row.get("slot", "").replace("`", "")
        rows_file.write("\t".join([row.get("level", ""), row.get("when", ""), slot_cell, row.get("command", "")]) + "\n")
slot_list = []
for line in levels_section.splitlines():
    if line.startswith("- "):
        slot_list.append(line[2:].split(":", 1)[0].replace("`", "").strip())
    elif slot_list and not line.startswith("  "):
        break
with open(sys.argv[3], "w") as slots_file:
    slots_file.write("".join(slot + "\n" for slot in slot_list))
PARSE
for level_and_name in smoke:Smoke property-based:PropertyBased "runtime evidence:RuntimeEvidence"; do
  level="${level_and_name%%:*}"; test_name="${level_and_name#*:}"
  check "TemplateLevelsTable_HasA${test_name}Row: the template gives a $level check its own row" \
    awk -F '\t' -v level="$level" '$1 == level { found = 1 } END { exit !found }' "$template_rows"
  check "TemplateLevelsTable_${test_name}RowSaysWhenItRuns: the $level row fills its when cell" \
    awk -F '\t' -v level="$level" '$1 == level && $2 != "" { found = 1 } END { exit !found }' "$template_rows"
  check "TemplateLevelsTable_${test_name}RowHasACommandCell: the $level row fills its command cell" \
    awk -F '\t' -v level="$level" '$1 == level && $4 != "" { found = 1 } END { exit !found }' "$template_rows"
done
check "TemplateLevelsTable_EveryRowNamesAKnownSlot: each row's slot cell, up to its first condition or second clause, is exactly one slot of the template's slot list" \
  awk -F '\t' 'NR == FNR { known[$0] = 1; next } { slot = $3; sub(/( when |[;,]).*/, "", slot); if (!(slot in known)) unnamed++; rows++ } END { exit unnamed > 0 || rows == 0 }' "$template_slots" "$template_rows"
check "TemplateLevelsTable_RowNothingRunsSaysNothing: every row whose command is not set up names the slot nothing, and there is at least one" \
  awk -F '\t' '$4 == "not set up" { unrun++; if ($3 != "nothing") misnamed++ } END { exit misnamed > 0 || unrun == 0 }' "$template_rows"

[ "$fails" -eq 0 ] && echo "testing-guide: ok" || { echo "testing-guide: $fails failed"; exit 1; }

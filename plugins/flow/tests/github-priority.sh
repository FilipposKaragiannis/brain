#!/bin/sh
# github-priority.sh: how a GitHub item reads its priority, through the github adapter and a fake
# gh in a throwaway repo. With no priority field a priority: label gives the priority and its rank
# in ready.priority_order, the ready list orders by it and ready.needs can ask for it; new.sh
# --priority writes the label and a child takes its parent's. Two labels read as the better one and
# the board's Health names the item. With the field configured the field wins and labels are
# ignored. Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

export FAKE_GH_DIR="$work/gh"
mkdir -p "$FAKE_GH_DIR" "$work/github" && cp "$plugin/tests/_fake_gh.py" "$FAKE_GH_DIR/"
ln -s "$plugin/tests/fake-gh.sh" "$work/github/gh"
PATH="$work/github:$PATH"; export PATH
github="$plugin/adapters/github"

# write_label_config <github block lines> <ready block lines>: a GitHub config with that order and needs.
write_label_config() {
  printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\n%bready:\n%b  priority_order: %s\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' "$1" "$2" "$3" > .flow/config.yaml
}
PRIORITY_ORDER_STARTING_AWAY_FROM_P0='[P3, P0, P1, P2]'
RANK_OF_P0=1; RANK_OF_P1=2; RANK_OF_P2=3
NEEDS_PRIORITY='  needs: [priority]\n'
PRIORITY_FIELD='  fields:\n    priority: Priority\n'
github_item_field() { "$github/read.sh" "$1" | json_value "$2"; } # github_item_field <id> <key>
# ready_position <id>: where the item stands in the ready list, from 0, or nothing when it is not in it.
ready_position() { "$github/list-ready.sh" | python3 -c 'import json,sys; item_ids=[item["id"] for item in json.load(sys.stdin)]; print(item_ids.index(sys.argv[1]) if sys.argv[1] in item_ids else "")' "$1"; }

new_repo labels
write_label_config '' "$NEEDS_PRIORITY" "$PRIORITY_ORDER_STARTING_AWAY_FROM_P0"
cat > "$FAKE_GH_DIR/issues.json" <<'JSON'
{"issues": [
  {"number": 90, "title": "Two priorities", "body": "", "state": "OPEN", "labels": ["size:S", "priority:P2", "priority:P0"], "url": "https://gh/90"},
  {"number": 93, "title": "Two priorities, the better first", "body": "", "state": "OPEN", "labels": ["size:S", "priority:P0", "priority:P2"], "url": "https://gh/93"},
  {"number": 91, "title": "No priority", "body": "", "state": "OPEN", "labels": ["size:S"], "url": "https://gh/91"},
  {"number": 92, "title": "Field and label", "body": "", "state": "OPEN", "labels": ["size:S", "priority:P0"], "fields": {"Priority": "P2"}, "url": "https://gh/92"},
  {"number": 94, "title": "The worst priority", "body": "", "state": "OPEN", "labels": ["size:S", "priority:P2"], "url": "https://gh/94"}
]}
JSON

echo "github priority labels: no priority field"
labelled_parent="$("$plugin/scripts/new.sh" task "Labelled parent" --size S --priority P1 2>/dev/null)"
check "CreateWithPriorityAndNoPriorityField_AddsAPriorityLabel: the label is where the priority lives without a field" \
  '"$github/read.sh" "$labelled_parent" | python3 -c "import json,sys; sys.exit(\"priority:P1\" not in json.load(sys.stdin)[\"labels\"])"'
check "ItemWithAPriorityLabelAndNoPriorityField_ReadsWithThatPriority: the label stands in for the missing field" \
  '[ "$(github_item_field "$labelled_parent" priority)" = P1 ]'
check "ItemWithAPriorityLabelAndNoPriorityField_RanksByItsPlaceInThePriorityOrder: P1 is second in an order that starts at P3" \
  '[ "$(github_item_field "$labelled_parent" rank)" = "$RANK_OF_P1" ]'
labelled_child="$("$plugin/scripts/new.sh" task "Labelled child" --size S --parent "$labelled_parent" 2>/dev/null)"
check "ChildOfALabelledParentWithNoPriorityField_TakesItsParentsPriority: a child inherits priority through the label as it would through the field" \
  '[ "$(github_item_field "$labelled_child" priority)" = P1 ]'
check "TwoPriorityLabelsWithTheWorseFirst_ReadAsTheOneEarlierInThePriorityOrder: P0 comes before P2 in the order, whatever the label order" \
  '[ "$(github_item_field gh#90 priority)" = P0 ]'
check "TwoPriorityLabelsWithTheBetterFirst_ReadAsTheOneEarlierInThePriorityOrder: the label order does not decide" \
  '[ "$(github_item_field gh#93 priority)" = P0 ]'
check "TwoPriorityLabels_RankByTheOneEarlierInThePriorityOrder: the rank follows the priority read" \
  '[ "$(github_item_field gh#90 rank)" = "$RANK_OF_P0" ]'
check "BetterPriorityLabelListedAfterAWorseOne_GoesAheadInTheReadyList: the ready list orders by priority, not by listing order" \
  '[ "$(ready_position "$labelled_child")" -lt "$(ready_position gh#94)" ]'
check "UnstartedItemWithNoPriorityLabel_LacksThePriorityReadyNeedsAsksFor: ready.needs reads the label as the priority" \
  '[ "$(github_item_field gh#91 needs)" = "[\"priority\"]" ]'
check "UnstartedItemWithNoPriorityLabel_IsNotReady: ready.needs holds it back" \
  '[ -z "$(ready_position gh#91)" ]'
check "ItemWithTwoPriorityLabels_IsNamedInHealthWithBothLabels: the owner sees which labels clash" \
  '"$plugin/scripts/board.sh" 2>/dev/null | grep -- "gh#90:" | grep -- "priority:P2" | grep -q -- "priority:P0"'

write_label_config '' '' '[P0, P1, P2]'
check "LabelledItemListedAfterAnUnlabelledOne_GoesAheadInTheReadyList: an item with no priority ranks last" \
  '[ "$(ready_position "$labelled_child")" -lt "$(ready_position gh#91)" ]'

echo "github priority labels: the priority field set"
write_label_config "$PRIORITY_FIELD" "$NEEDS_PRIORITY" "$PRIORITY_ORDER_STARTING_AWAY_FROM_P0"
check "PriorityFieldSetAndAnItemWithOnlyLabels_ReadsWithNoPriority: the field is the only source once configured" \
  '"$github/read.sh" gh#90 | python3 -c "import json,sys; sys.exit(json.load(sys.stdin)[\"priority\"] != \"\")"'
check "PriorityFieldSetAndADifferentLabel_ReadsTheField: the field wins over the label" \
  '[ "$(github_item_field gh#92 priority)" = P2 ]'
check "PriorityFieldSetAndADifferentLabel_RanksByTheField: the rank follows the field" \
  '[ "$(github_item_field gh#92 rank)" = "$RANK_OF_P2" ]'
check "PriorityFieldSetAndTwoPriorityLabels_LeavesTheItemOutOfHealth: labels the field overrides clash with nothing" \
  '"$plugin/scripts/board.sh" 2>/dev/null > "$work/board.labels" && grep -q "^## Items" "$work/board.labels" && ! sed -n "/^## Health/,/^\$/p" "$work/board.labels" | grep -q -- "gh#90:"'
field_priority_item="$("$plugin/scripts/new.sh" task "Field priority" --size S --priority P1 2>/dev/null)"
check "CreateWithPriorityAndThePriorityFieldSet_AddsNoPriorityLabel: the field carries the priority" \
  '"$github/read.sh" "$field_priority_item" | python3 -c "import json,sys; sys.exit(bool([label for label in json.load(sys.stdin)[\"labels\"] if label.startswith(\"priority:\")]))"'

if [ "$fails" -eq 0 ]; then echo "github-priority: ok"; else echo "github-priority: $fails failed"; exit 1; fi

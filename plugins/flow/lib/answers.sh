# answers.sh: which gated items the owner can answer on their tracker, from the flow records.
# Sourced after lib/flow.sh by jobs/next.sh and each adapter's answers.sh, never run.

# answerable_gates [<item>...]: each item whose record holds a gate the owner answers on the
# tracker, one per line: any gate but merge, which clears when its PR is merged. With items given,
# only those of them. A record that does not parse is left out, as record_list leaves it.
answerable_gates() {
  record_list gates 2>/dev/null | cached_python3 -I -c '
import json, sys
given = set(sys.argv[1:])
for line in sys.stdin:
    row = json.loads(line) if line.strip() else {}
    item = row.get("item")
    if item and row.get("gate") != "merge" and (not given or item in given):
        print(item)' "$@"
}

# answer_items_required <adapter> <item>...: refuses, exit 2, an item that is not of the adapter's
# shape (item_id_shaped), before the adapter reads its tracker.
answer_items_required() {
  answer_required_adapter="$1"; shift
  for answer_required_item in "$@"; do
    if [ "$(adapter_for "$answer_required_item")" != "$answer_required_adapter" ] || ! item_id_shaped "$answer_required_item"; then
      die "$answer_required_item is no $answer_required_adapter item id" 2
    fi
  done
}

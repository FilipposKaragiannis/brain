# _state_fixture.sh: the fixture state.sh, state-views.sh, state-join.sh and state-readers.sh source: the base
# fixture, a repo on the local adapter, the helpers that read an item's flow record and its tracker
# side by side, and one gate record and one run record as notify.sh and next.sh write them. Each
# suite enters the sandbox, then makes its repo with new_repo records, whose config sets the mode:
# FLOW_TRACKER_STATE is unset. Sourced, never run.
. "$(dirname "$0")/_base_fixture.sh"
unset FLOW_TRACKER_STATE

record() { "$plugin/scripts/state.sh" "$@"; }
take() { env FLOW_MACHINE="$1" sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && take_item "$1"' take "$2"; }
closed_record() { open_record="$(record path "$1")"; printf '%s/closed/%s' "$(dirname "$open_record")" "$(basename "$open_record")"; }
tracker_state_is() { grep -v '^tracker_state:' .flow/config.yaml > "$work/config.yaml"; [ -z "$1" ] || echo "tracker_state: $1" >> "$work/config.yaml"; cp "$work/config.yaml" .flow/config.yaml; }
# tracker <item> [<key>]: the tracker's own state of the item, or one key of it.
tracker() { "$local_adapter/read.sh" "$1" | json_value "state${2:+.$2}"; }
item_file() { printf '.flow/items/task/%s.md' "${1##*/}"; }
gate_file() { printf '.flow/gates/%s.json' "$(slug "$1")"; }
run_file() { printf '.flow/runs/%s.json' "$(slug "$1")"; }
claim_step() { json_value step < "$("$plugin/scripts/steward.sh" find "$1")/.flow/claim.json"; }
with_item() { python3 -c 'import json,sys; view=json.load(sys.stdin); view["item"]=sys.argv[1]; print(json.dumps(view, sort_keys=True))' "$1"; }
canonical() { python3 -c 'import json,sys
text=sys.stdin.read().rstrip("\n")
try: print(json.dumps(json.loads(text), sort_keys=True))
except ValueError: print(text)'; }
first_key_differing_from_tracker() {
  tracker_keys="$("$local_adapter/read.sh" "$1" | python3 -c 'import json,sys; print(" ".join(json.load(sys.stdin)["state"]))')"
  [ -n "$tracker_keys" ] && for key in $tracker_keys; do
    [ "$(record get "$1" "$key" | canonical)" = "$(tracker "$1" "$key" | canonical)" ] || { echo "$key differs"; return 1; }
  done
}

gate_record='{"gate":"ambiguity","item":"ignored","message":"Which row owns the retune?","time":"2026-11-15T10:00:00Z","host":"codex","options":[{"label":"Keep both rows","text":"Both rows stay","recommended":true}],"raised_by":"step design","answered_by":"step plan","condition":"ci:down","footer":"gate.sh clear with an option"}'
run_record='{"item":"ignored","step":"implement","profile":"task-M","worktree":"/tmp/wt-2","reports":"/tmp/reports","host":"codex","started":"2026-11-15T11:00:00Z","pid":4242,"touches":["src/a/**"]}'


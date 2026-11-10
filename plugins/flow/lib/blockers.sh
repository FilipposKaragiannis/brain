# The native blockers of an item (blocked_by on the tracker) and the note a claimed item keeps
# while it waits on them. Sourced after lib/flow.sh by scripts/next.sh. An owner may block an item
# after its claim, so a blocker holds the item at every step, claimed or not.

# comma_list: the lines on stdin as one line, ", " between them.
comma_list() { paste -sd, - | sed 's/,/, /g'; }

# adapter_open_blockers <item-json>: each of blocked_by its adapter does not read as closed, one per
# line. A blocker that cannot be read still holds, as in filter-ready.sh.
adapter_open_blockers() {
  json_list "$1" blocked_by | while IFS= read -r blocker; do
    [ -n "$blocker" ] || continue
    blocker_status="$(json_get "$(adapter read "$blocker" </dev/null 2>/dev/null)" status)"
    [ "$blocker_status" = closed ] || printf '%s\n' "$blocker"
  done
}

# open_blockers <item-json>: the item's open blockers, comma-separated. A tracker that keeps its own
# list (open_blockers) saves a read per blocker.
open_blockers() {
  if [ -n "$(json_get "$1" open_blockers)" ]; then
    json_list "$1" open_blockers | comma_list
    return
  fi
  adapter_open_blockers "$1" | comma_list
}

# wait_note <item> <blockers>: blocked.md in the reports of a claimed item that waits, so the step
# that starts once its blockers close is told to merge its base first. An item that holds no claim
# has no branch to bring in step.
wait_note() {
  claimed_worktree="$("$FLOW_PLUGIN/scripts/steward.sh" find "$1" </dev/null 2>/dev/null)"
  [ -n "$claimed_worktree" ] || return 0
  mkdir -p "$(reports_dir "$1" "$claimed_worktree")" && printf '%s\n' "$2" > "$(reports_dir "$1" "$claimed_worktree")/blocked.md"
}

# wait_notes <held-back-json>: wait_note for each claimed item the ready filter held back for its
# open blockers (FLOW_READY_NOTES in filter-ready.sh). A pick never names such an item, so its note
# is written here, while it waits.
wait_notes() {
  printf '%s\n' "$1" | python3 -I -c '
import json, sys
for note in json.loads(sys.stdin.read() or "[]"):
    if note["why"] == "blocked" and note.get("worktree"):
        print(note["id"] + "\t" + ", ".join(note.get("blocked_by", [])))' |
    while IFS="$(printf '\t')" read -r waiting_item waiting_on; do wait_note "$waiting_item" "$waiting_on"; done
}

# wait_over <reports>: the blockers a claimed item waited on, from its blocked.md, once its step
# runs again; nothing when it did not wait.
wait_over() { [ ! -s "$1/blocked.md" ] || cat "$1/blocked.md"; }

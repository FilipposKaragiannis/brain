bump: minor

- The Jira adapter answers gates on the issue: `adapters/jira/answers.sh` clears a gate when the
  owner comments `/answer <text>` (or `/answer` alone, as recommended) after its `**Gate: ...**`
  comment. The owner is the API token's user, or an account id or email in the new
  `jira.answer_from` list. The merge gate is left to the merge. `gate.sh` comments "Gate cleared"
  on the issue as the receipt.
- `adapters/jira/vocabulary.sh` prints the project's issue types (no sub-tasks) and the options of
  the `jira.fields.area` field, so `flow:new` offers Jira's own names. Jira has no `sync.sh`: its
  board columns are workflow statuses each project shapes its own way, the `step:` and `gate:`
  labels already show where an item is, and closing takes the done transition.
- Slack notifications know an item id by the adapters' prefix files, so `jira:WID-7` reads as code
  and a new adapter's ids do too. A gate on an item whose adapter has `answers.sh` says to answer
  on the issue; any other gate says to answer in a session.
- `board.sh` shows what it can when a tracker's list fails: the other trackers' items, and each
  failed tracker with its exit code and last stderr line (`tracker_errors` in `--json`, a
  "Trackers not read" section in the text board), where before the whole board stopped or the
  items went missing without a word.
- `init.sh` writes the commented `jira.limit` and `jira.answer_from` keys into a new config.

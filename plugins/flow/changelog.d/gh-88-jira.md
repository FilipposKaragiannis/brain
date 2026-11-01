bump: minor

- Jira Cloud is a tracker: `adapters/jira/` meets the adapter contract through the REST API v3
  and `curl`, with ids `jira:<KEY>-<n>`. Set `adapters.default` (or `adapters.<kind>`) to `jira`
  and `jira.site`, `jira.project` and `jira.email`; the token comes from `JIRA_API_TOKEN` in the
  environment only, reaches `curl` on stdin, and without it every script refuses with the reason.
- Each kind is created as the issue type `jira.types.epic|task|bug` (default Epic, Task, Bug). The
  flow state lives in the same labels GitHub uses (`step:`, `gate:`, `wt:`, `flow:`, `size:`) and
  whole in the issue property `flow-state`. The priority is Jira's own; the size is the field
  `jira.fields.size` when set, else a label; `ready.needs` and `ready.priority_order` apply.
- Blockers are Blocks links (a blocker in another tracker is a `Blocked by:` line), `link-pr` adds
  a remote link and a comment, `close` takes `jira.transitions.done` (default the transition named
  Done), and a 5xx or a dropped connection is tried again like `gh`, except for a create.
- `init` writes the `jira:` keys, commented, into a new config. `tests/fake-jira.sh` stands in for
  Jira's `curl`, and `tests/run.sh` runs the contract suite for `jira` too.

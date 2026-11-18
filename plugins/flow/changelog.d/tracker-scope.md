bump: minor

- `<tracker>.scope` in `.flow/config.yaml` (`github.scope`, `jira.scope`, `local.scope`) bounds
  every list and search of a shared tracker: the board, `next`, the health and comments jobs and
  `answers` see only the items it keeps. It takes `assignee`, `status`, `labels` and `kinds`, or
  the tracker's own `query` alone, applies beside a pick filter, and leaves every read as it was
  when unset. `init --check` names a scope the tracker cannot map.
- `next <item>` refuses a named item outside the scope that holds no claim, and
  `steward.sh claim` refuses a new claim of one, both with exit 2; an item claimed before it left
  the scope keeps its claim, its worktree and its run, and `adhoc:` claims are never scoped.
- An adapter has a new required op, `in-scope.sh <id>`: exit 0 inside the scope, 1 outside.

bump: minor

- `next --pick <name>` takes the first ready item the filter `pick.<name>` in `.flow/config.yaml`
  keeps: `assignee` (`me`, a login or an email), `status`, `labels` and `kinds` (any of each),
  `trackers`, or `query`, one tracker's own search passed as written (JQL on Jira, search
  qualifiers on GitHub). Readiness, blockers, gates and the priority order apply after the
  filter; without `--pick` nothing changes. An unknown name exits 2 naming the filters there are.
- Each adapter maps the fields in `list` and `list-ready --pick <name>` and names them in a new
  `pick-fields` file; a field it cannot map (local has no `query`), a query without exactly one
  tracker or beside a neutral field, and a tracker the flow does not read are refused, exit 2.
  `adapters/README.md` documents the mapping and the contract suite checks it for github, local
  and jira.
- `jobs/next.sh` and `run-unattended.sh` take `--pick <name>`, so a named schedule runs one
  filter: `jobs.schedule.next-mine: every 30m --pick mine`. A bad filter stops the run before it
  reads the tracker.
- The Jira adapter counts a listed epic's open children with a second search when a filter
  narrows the list, so an epic whose children the filter leaves out still counts them.

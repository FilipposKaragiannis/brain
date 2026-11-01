# console

## 0.13.0 (2026-11-01)

- Status colours mean one thing each: orange you decide (gate), teal ready (PR mergeable or
  approved), blue changes asked, red broken (PR failing, job failed, dead run, host stopped), pink
  stores disagree, purple stale, grey a chore (needs field). Pulls and Gates use the same set, and
  the ink reads at 4.5:1 on its tint and on the panel in both themes.
- Overview: the Settings text link goes (the top bar's button stays), Jobs run on lists every host
  the schedules and workers use, Sources gets a refresh button that posts `/refresh` for every
  source, Running now links to Agents and Jobs, and the theme switch is a moon or sun icon.
- A plugins footer lists each plugin of flow's marketplace with the version Claude Code and Codex
  have, marks the ones that differ, and says which flow the scripts use and where it was found.
- Agents and Jobs are two pages: Agents holds the runs, your sessions and the ones ended in the
  last day; Jobs (`#/<project>/jobs`) holds the schedules, the Schedule / Run once panel, Events
  and the stopped-host cards. The nav says "N running" on Jobs while jobs run, old Agents links
  still open Agents, and host-stopped and job-failed rows on Needs you open Jobs.
- Daemon: `ProjectInfo.jobHosts` and `ProjectInfo.plugins` (from Claude's installed plugins, the
  project's entry over the user's, and from Codex's config and plugin cache, read with the files
  source); `POST /api/projects/<id>/refresh` publishes the snapshot even when nothing changed;
  `Gate.session` names the session that raised a waiting gate, found from the transcripts in its
  worktree, and `terminal.open` takes `gate=<item>` to resume it.

## 0.12.0 (2026-11-01)

- The Worktree pool page has `worktree_name`, the name a worktree the pool adds gets, such as
  `../{repo}-wt-{n}`.
- The daemon looks in the plugin cache on start and then once a minute. While the cache holds a
  newer console than the one it runs, `brain-console status` names both versions and
  `brain-console update`, and the page shows the same notice as a banner at the top. Both go once
  the daemon runs the newest cached version. The snapshot and `GET /api/settings` carry it as
  `newerConsole`.
- A hand edit to `~/.config/brain-console/config.json` takes effect within a minute: the daemon
  checks the file's modification time, watches new roots, drops removed ones and logs
  `config.reloaded`. Projects given by `--project` or `BRAIN_CONSOLE_PROJECTS` stay fixed. A
  file that does not parse or fails the settings checks is refused and logged as
  `config.refused`: the daemon keeps what it loaded, and `status` says the file differs, with
  the reason (`fileError` in `GET /api/settings`).
- `brain-console status` lists the projects the running daemon watches.
- Tracker settings: a "Where items come from" part with `trackers` (github, local), beside the
  per-kind fields for where new items go. The GitHub part shows while the flow reads GitHub
  (`trackers`, else some `adapters` key), and the pulls source and the header's issues link follow
  the same read set instead of `adapters.default` alone.
- Readiness settings edit `ready.needs` and `ready.priority_order`, shown for every tracker. While
  the file leaves one out (an empty list saved there counts as set) the form starts at the
  deprecated `github.ready_needs` or `github.priority_order` the flow still reads, and the old
  key shows read-only with a Clear.
- The tracker settings take `jira`, the Jira Cloud adapter flow now ships, for new items of every
  kind.
- The Reviews page has a reviewer list per author host, `reviews.reviewers.claude` and `.codex`,
  and the default list, `.default`. A plain `reviews.reviewers` list shows as the default, and a
  save of a host's list turns it into the map with that list as its default. The PR cards offer
  every name the lists hold.
- Worktrees: Reserve in the toolbar runs the new `worktree.reserve` action (`steward.sh reserve`,
  optional `name`, under the pool lock); a reserved card says who reserved it and has Release. A
  reservation is never stale: no `idle` or `stale-branch` flag, and no item on its card.
- Worktrees: Sweep beside Run health runs the new `steward.sweep` action (`steward.sh sweep
  --lock`, under the pool and health job locks). Its note names the worktrees freed and the merge
  gates cleared, or says nothing landed, or that a sweep already runs.
- The app's `package.json` and `package-lock.json` (daemon and UI) carry the plugin's version,
  0.11.0 here instead of 0.8.0 and 0.7.2. The hosts cache the plugin by that version, so the
  installed console no longer looks older than the cached one. `tools/release.sh` now stamps it
  on every release and `tools/lint.sh` fails when they differ.

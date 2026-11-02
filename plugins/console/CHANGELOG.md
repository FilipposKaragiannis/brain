# console

## 0.15.0 (2026-11-02)

- The daemon's action tests wait for the event they need, not a fixed 10 ms: an action's end as
  the runner announces it, the monitor reads the runner asked for, and the config writer being
  called. Under load the hand-off's second jobs read and the sync hand-off's failed note no longer
  fail the suite.
- Tests prove that adding a project and watching it work when its `.flow/` is excluded in
  `.git/info/exclude` and untracked, as `flow:init` now leaves it: the console reads the flow home
  and the claims from the disk, and the worktrees count no dirty files for them. No code changed.
- The console routes an item id by the flow plugin's adapter prefix files, so `jira:WID-7` (and an
  id of any adapter added later) passes to gate, run, claim, quiz and step-sync actions, and
  step-sync writes through the item's own adapter. An id with no adapter's prefix is refused with
  the prefixes the plugin has; a plugin before flow 1.28.0, with no prefix files, keeps `gh#` and
  `local:`.
- The Jira token reaches the flow scripts: `JIRA_API_TOKEN` passes from the console's environment
  to every script, and `brain-console install` keeps it in the launch agent's plist, now written
  readable by its owner alone (0600). When jira is a tracker and the console has no token, the
  board and the header say so and how to fix it.
- The header lists every tracker the flow reads (`trackers`), each linked to its items (GitHub's
  issues, `<jira.site>/browse/<jira.project>`), and marks one the board could not read with why;
  the Board page says the same in a banner above the list. A worktree whose item the board did
  not list still links its issue page. The snapshot is schema 8: `project.trackers` replaces
  `project.trackerUrl`.
- Pull requests are read wherever `github.repo` is set, whatever tracker holds the items, since the
  flow keeps every PR on GitHub.
- The settings page has a Jira part on the Tracker page (`jira.site`, `jira.project`,
  `jira.email`, `jira.types`, `jira.fields`, `jira.transitions.done`, `jira.limit`,
  `jira.answer_from`), shown while jira is a tracker. The GitHub repository field shows whatever
  the tracker, and only the GitHub issue keys hide while no tracker is GitHub.
- The Jobs page offers the config's pick filters for a next run: the Run once and Schedule forms,
  Edit… on a next schedule and the settings' schedule builder have a Filter field (every ready
  item, or one filter), sent as `--pick <name>`. `job.start` takes `pick` for next, refused
  beside an item. Needs flow with pick filters.
- Settings, Readiness lists each filter under `pick` with its assignee, statuses, labels, kinds,
  trackers and query, editable in place; the snapshot's project carries the filters as `picks`.

## 0.14.0 (2026-11-02)

- The quiz the flow's explain step writes is taken in the console. A gate whose item has a quiz
  (`<reports>/quiz.md`, read with the gates from the claimed worktree, the pool and the main
  worktree) shows a quiz panel on its Gates card, and so does the PR card of that item: Take the
  quiz opens the questions, Check my answers grades the letters on the page and runs the new
  `quiz.answer` action (`quiz.sh answer <item> 1b 2a 3c`, flow 1.28.0), which keeps the result as
  `<reports>/quiz.json` and marks the draft PR ready for review on a pass. The results mark each
  question, show the right choice for a wrong one with the question's Because line, and offer
  Take it again; a kept result shows its score with See results. A merge gate or a PR card on a
  draft with a quiz still to pass says that is what holds it. The snapshot is schema 7: a gate and
  a pull carry `quiz`.

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

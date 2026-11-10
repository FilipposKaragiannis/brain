# console

## 0.19.1 (2026-11-10)

- The Board shows a claimed item as `blocked` while flow holds it behind an open blocker
  (`open_blockers`, gh#168): flow's next job passes such an item over at every step, so it no
  longer shows as `waiting` for a worker. A run already under way when the blocker was added stays
  `running`.

## 0.19.0 (2026-11-08)

- The Board shows an owner's answer to a cleared gate while it waits on a run (flow's
  `answer_pending`, #157): beside the item's step, and in its Gate fact as `cleared, answer waits
  on the comments job` or `on next`. The snapshot's items carry it as `answerPending`.
- The agents page shows every working agent, claude or codex, headless included. Each run card
  says its host, item, step or flow job, worktree, that it is headless, when its process started
  and how long it has run, and, while folded, its latest transcript line.
- A `codex exec -C <dir>` run started from the project root, as flow starts a Codex run, is listed
  under the worktree `<dir>` names and finds its Codex session there. Only codex's options before
  its prompt count, so a `-C` the prompt mentions does not.
- An agent carries `step` and `job` beside `item` (snapshot schema 16). `job` is the flow job it
  runs under, found by walking its parents in the one ps read: a comments, health, intake or retro
  run at the project root is named instead of anonymous. `item` falls back from the claim to the
  run the agent works for, and `step` comes from that run when it is of the same item.
- The transcript route reads Codex sessions too: messages, reasoning summaries, shell commands
  with their script, tool calls, and an `error:` line after one that failed. A folded card's one
  line reads a 64 KB tail, not 4 MB; the read still doubles while it holds too few lines.

## 0.18.0 (2026-11-08)

- A claimed pool worktree with no run, no agent and no gate no longer reads as work going on: it
  is `waiting` ("waiting for a worker · next <step>") or, when flow holds its item behind another,
  `held` ("held behind gh#X", linked, with the reason). Board, Overview and Worktrees say it the
  same way, the step reads as the next one, and a held claim is never flagged idle.
  A hold whose holder is closed reads as `waiting`: flow lets the item through and lifts the tag
  on its next run. The board lists open items only, so a closed holder is told by the board's
  `holders` read (flow's `board.sh --json`); one that could not be read keeps its hold. An item at
  or before its profile's plan step (a plan sent back at its gate) reads as `waiting` too, as flow
  runs that plan while held.
- The snapshot carries `heldBy` and `heldReason` on items and worktrees from flow's `held_by` and
  `held_reason`, `counts.waiting`, `counts.held` and `readiness.held`; schema 15.
- Items to close (every step ran with no gate up, or every child of a split is closed) get their
  own Ready to close section on the Gates screen, each saying what to do, with the PR's merge
  button when it is ready. No flow gate is made up for them, and the Overview's needs-you count,
  the Gates heading and its nav badge now count the same items.
- Every pool card on Worktrees carries "Merge <base> in", whatever its state, so a branch far
  behind under a gate can still be brought up to date from the console. The button is disabled,
  with the daemon's reason on hover, while the worktree is unclaimed, unread by git, has
  uncommitted files, a run record or an agent; it is primary while the branch is far behind. The
  stale card says its way out in words. The health job's own sync notes are unchanged.

## 0.17.0 (2026-11-06)

- Agents shows how each of your own sessions stands: "busy", "idle 3d 2h" from claude's
  `~/.claude/sessions/<pid>.json` (read only when its pid, folder and start are the process's), or
  its age for a Codex session or a claude with no such file. A session idle for
  `jobs.health.stale_session` (24h unset), or with no status running that long, is tagged stale;
  a busy one never is. Stale sessions come first, and the "Your sessions" fold opens by itself
  while any is stale, with the count in its heading. Running now on the overview says "N stale
  sessions: <worktrees>" with a link to Agents. The flow settings form gains the key.
- Stop session on each session row ends it with SIGTERM (`session.stop`, `kill -s TERM <pid>`,
  never SIGKILL), after a second press to confirm. It is refused unless the snapshot lists the pid
  as a session started when the page says, and just before the signal the daemon reads the pid
  again and stops nothing unless it still runs that claude or codex session, so a pid a later
  process took is never signalled. A stop starts on a full runner, like the other stops.
- The snapshot is schema 14: an agent gains `startedAt` and `activity` (`{status, since}` or null),
  and the project gains `staleSessionSeconds`.
- Settings shows `jobs.comments_workers` under Comments job: how many PRs one comments run
  addresses at once. Unset, 1.
- `claude mcp serve` is never listed as a session or an agent: Claude's MCP server serves
  another client from whatever folder it started in, as flow already reads it.
- Agents lists the Claude and Codex servers working in the project's worktrees in a read-only
  "Servers" fold after your sessions: the Claude daemon, Claude's MCP server, the Codex app server,
  its pid loop and its exec server, each with its pid, worktree and how long it has run, and its
  command on hover. They are never sessions, and the comments and health jobs ignore them; one
  working outside the project, such as the Codex app bundle's in your home folder, is not listed.
  The snapshot (still schema 14) gains `servers`.

## 0.16.0 (2026-11-04)

- The Pull requests screen follows the prototype. Each card's head names its branch and base and
  links Open on GitHub; six health cells (state, checks, conflicts, review, threads, quiz); a
  "Checks on <head>" list with each failed or running check linked to its run and the passed ones
  folded; the reviewers; a "Today" timeline of the flow's events on the PR's item; Merge now,
  disabled with the reason while the PR is not ready.
- Merge when green arms GitHub's auto-merge (`pr.auto-merge`, `gh pr merge --auto --squash`), and
  Disarm takes it back (`--disable-auto`); an armed card says so. It is not offered while a
  review holds the PR that GitHub would merge past: a reviewer asked by a mention, a requested or
  optional review, a request for changes or an open thread.
- Ask the agent to fix the checks, on a PR whose checks fail, runs the comments pass on its item
  and PR now; the pass's new Checks step fixes them.
- The head line counts the PRs merged today and offers Run comments job now; a Merged today list
  under the cards shows each with its item, time, how long it was open and its branch.
- The `pulls` source reads each check's latest run, the head commit, the auto-merge and the PRs
  merged since local midnight. The snapshot is schema 13: `PullRequest` gains `checkRuns`, `head`,
  `autoMerge`, `changesRequested` and `reviewsRequested`, and the snapshot gains `mergedToday`.
- A failed process lookup never reports a live run dead. A ps that fails, times out or lists
  nothing makes the process list `unavailable`, and an lsof that fails, times out or gives a pid
  no working directory makes it `partial`, never an empty list that reads as "nothing runs"; the
  last read's agents stand meanwhile. The snapshot carries it as `processList` with the reason
  and the failed lookup, the `processes` source turns red ("process list unavailable: ps timed
  out after 10s"), and the daemon logs `processes.lookup.failed` with the command, exit code,
  timeout, duration and stderr, then `processes.lookup.recovered`.
- A run's `alive` is now `liveness`, by flow's own rule: `alive` while an agent works in its
  worktree or the pid its record names still runs a claude, codex or the unattended loop that
  started no later than the record; `unknown` while the process list is not complete; `starting`
  within `jobs.health.grace`; `dead` only after that. Only a dead run gets the `dead-run` flag,
  the Needs you row, the disagreement and Resume; Agents and Worktrees say why the others are not
  shown dead, and Agents shows an alive run whose agent was not located as a card from its record.
  The snapshot is schema 11.
- A Pull requests card offers Force merge (`pr.merge` with `force=true`, which adds `--admin` to
  `gh pr merge`) on a PR whose checks fail, or that is approved while GitHub blocks the merge.
- A conflicting PR's card offers Resolve conflicts: one comments pass for its item now
  (`job.start` with job comments, the item and the PR, which `jobs/comments.sh` takes as the
  target, so an item that recorded no PR still gets the pass), which merges the base in first;
  the card says the pass is running while it runs.
- The review ask offers the project's reviewers, then each of codex, claude and copilot not among
  them, then a GitHub login.
- A PR whose item recorded no PR links to the open item whose task branch `flow/<slug>` is its
  head branch. Each pull in the snapshot carries GitHub's `mergeState`.
- Each free worktree card has its own Reserve button, which reserves that worktree; the toolbar's
  Reserve, which took whichever worktree was free, is gone. A reserved card says "reserved by
  <who>" and shows Release in the same place, with a title saying it gives the reservation back.
  The button's running and outcome states show on the card that was pressed. It needs the flow
  release whose `steward.sh reserve` takes a worktree; an older steward refuses it as an unknown
  option, and the card says so.
- `worktree.reserve` takes an optional `target`, the name of a pool worktree, and passes its path
  to the steward. A target that is not a pool worktree is refused.
- On the Agents page a run, one of your sessions or an agent ended in the last day shows only
  Open session when it has a session to resume, and Open in Terminal only when it has none: both
  opened a terminal in the same folder. Worktree cards and job rows keep Open in Terminal.
- A pool worktree whose claimed item has an open PR and that holds an interactive session carries
  the `comments-skipped` flag: flow's comments job skips that PR while the session stays, so its
  review comments wait (schema 12).
- The Overview's Pool module says "The comments job skips N worktree(s): <names> (a session works
  there)" with a link to Worktrees, and the PR card says "The comments job skips this PR while a
  session works in <worktree>".
- A Retro page (`#/<project>/retro`, in the nav) shows what the flow learnt: a head line with the
  lessons in all, those since the last retro and when the last retro ran; the lessons grouped by
  kind then rule, each with its item and step; and every retro with the lessons it read and its
  report rendered. "Run retro now" starts the retro job through `job.start`, and the Overview
  counts the lessons since the last retro with a link to the page.
- The `files` source reads `lessons.jsonl`, `retros.log` and `reports/retro-<date>.md` from the
  flow home; the snapshot carries `lessons`, `retros` and `counts.lessonsSinceRetro` (schema 10).
  A missing file is no lesson and no retro, and a malformed line is skipped.
- Merge and Force merge no longer pass `--delete-branch` to `gh pr merge`: since gh 2.103 it
  removed the pool worktree that held the branch. The sweep frees the worktree and the branch.

## 0.15.2 (2026-11-03)

- The flow settings no longer offer `retro.commit` (Commit the retro lessons): the retro job
  commits nothing now, as its lessons stay on this machine under `.flow/`.

## 0.15.1 (2026-11-02)

- A gate's row in Needs you names its gate on the chip (`merge`, `escalation`, `plan-approval`
  …) instead of `gate`, so a narrow panel that clips the title still says which gate waits. The
  attention row carries the kind as `gate` (null on every other row); the snapshot is schema 9.
- Tests prove a project on the local tracker with `github.repo` set and no `trackers` gets what
  0.15.0's pulls read gave it: `pulls` reads ok, its open PRs list and link to the local item
  whose `pr` names them, the merge gate card carries a mergeable PR, a `pr-mergeable` row reaches
  Needs you, and the monitor sweeps a merge gate whose PR left the open list. Without
  `github.repo` the source still says it does not apply.

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

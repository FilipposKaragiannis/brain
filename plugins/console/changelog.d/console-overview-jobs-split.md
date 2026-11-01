bump: minor

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

bump: minor

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

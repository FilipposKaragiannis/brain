bump: minor

- The Jobs page offers the config's pick filters for a next run: the Run once and Schedule forms,
  Edit… on a next schedule and the settings' schedule builder have a Filter field (every ready
  item, or one filter), sent as `--pick <name>`. `job.start` takes `pick` for next, refused
  beside an item. Needs flow with pick filters.
- Settings, Readiness lists each filter under `pick` with its assignee, statuses, labels, kinds,
  trackers and query, editable in place; the snapshot's project carries the filters as `picks`.

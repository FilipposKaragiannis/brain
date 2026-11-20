bump: minor

- A Graph report screen (`#/<project>/graph`) shows the flow's graph report of the project: per
  step its runs, median time, the time nine runs in ten finish within, failed runs, cost and runs
  per item for the last 7 days, the steps whose median grew by half or more against the 7 days
  before, and the five items that took the most step time. It is read when the screen opens and
  with "Read again", through the new route `GET /api/projects/<id>/graph-report`. Needs flow
  1.44.0; with an older flow the screen says so.
- The demo's run log holds two weeks of step runs, with a verify step four times slower in the
  second, so the screen has a report to show.

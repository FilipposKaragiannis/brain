bump: minor

- The flow keeps a history of the steps that outlives the run log. The run log is cut at 4000
  lines and its step runs were lost with it. Now `<flow home>/log/steps.daily.jsonl` gets one
  line per day (UTC) and step: runs, total and median seconds, nine-in-ten time, failed runs,
  cost and items. A day is kept once, a full day after it ended, so a run that began before
  midnight and ended after it is counted. Until then its step records are carried over every cut
  in `steps.pending.jsonl`. Every graph report keeps the history first, and so does the job that
  cuts the log; one lock keeps two of them from writing a day twice.
- `graph-report.sh --json` prints `{days, now, markdown, daily}`: the report and the daily lines
  of the last 30 days, the days not yet kept counted from the records. The console draws its
  chart from it. `--keep` only keeps the history and prints nothing.
- The report counts the step records of the pending file too, each once.

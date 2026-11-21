bump: minor

- The flow keeps a history of the steps that outlives the run log. Each finished day (UTC) is
  kept once in `<flow home>/log/steps.daily.jsonl`, one line per day and step: runs, median,
  nine-in-ten time, failed runs, cost and items. The run log is cut at 4000 lines and its step
  runs were lost with it; the job that cuts it now keeps the days first, and every graph report
  does too.
- `graph-report.sh --json` prints `{days, now, markdown, daily}`: the report and the daily lines
  of the last 30 days, the day under way counted from the log. The console draws its chart from
  it. `--keep` only keeps the finished days and prints nothing.

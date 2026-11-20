bump: minor

- `scripts/graph-report.sh [--days N]` prints what each step of the flow cost over the last N
  days (default 7) from the run log, with no model: per step the runs, the median time, the time
  nine runs in ten finish within, the failed runs, the cost and the runs per item; the steps
  whose median grew by half or more against the N days before; and the items that took the most
  step time.
- The retro job writes that report to `.flow/reports/graph-<date>.md` and names it to the retro,
  so a step that got slower or runs again and again is a finding beside the lessons.

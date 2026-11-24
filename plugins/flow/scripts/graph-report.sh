#!/bin/sh
# graph-report.sh [--days N] [--json | --keep | --slower]: what each step of the flow cost over the
# last N days (default 7), from the run log in <flow home>/log, as Markdown on stdout
# (scripts/_graph_report.py): the verdict, then per step the runs, the median time, the time nine
# runs in ten finish within, the failed runs, the cost and the runs per item; the steps whose
# median grew against the N days before; and the items that took the most step time. No model
# runs. The retro job writes it to <flow home>/reports/graph-<date>.md and hands it to the retro.
# The run log is cut at 4000 lines, so every call but --slower first keeps the history of the steps
# (scripts/_step_history.py): <flow home>/log/steps.daily.jsonl gets one line per day and step
# once the day is settled, a full day after it ended, and steps.pending.jsonl carries the step
# records of the younger days over every cut. --keep does only that (the job that cuts the log
# calls it first). --json prints {days, now, markdown, daily}: the report and the daily lines of
# the last 30 days, which the console draws its chart from. --slower prints only the steps the
# verdict names as slower, a line each: the step, its median now and its median before, apart by
# tabs; it keeps no history, so the health job asks it on every pass.
# FLOW_NOW (an ISO time) stands in for the clock, for tests.
. "$(dirname "$0")/../lib/flow.sh"
DEFAULT_DAYS=7
USAGE="usage: graph-report.sh [--days N] [--json | --keep | --slower]"
days="$DEFAULT_DAYS"; output=markdown
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || die "$USAGE" 2; days="$2"; shift 2 ;;
    --json) output=json; shift ;;
    --keep) output=keep; shift ;;
    --slower) output=slower; shift ;;
    *) die "$USAGE" 2 ;;
  esac
done
case "$days" in ''|*[!0-9]*|0) die "--days takes a whole number from 1, not $days" 2 ;; esac
cached_python3 -I "$FLOW_PLUGIN/scripts/_graph_report.py" "$(flow_home)/log" "$days" "${FLOW_NOW:-$(now_iso)}" "$output"

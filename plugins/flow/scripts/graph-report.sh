#!/bin/sh
# graph-report.sh [--days N]: what each step of the flow cost over the last N days (default 7),
# from the run log in <flow home>/log, as Markdown on stdout (scripts/_graph_report.py): per step
# the runs, the median time, the time nine runs in ten finish within, the failed runs, the cost
# and the runs per item; the steps whose median grew against the N days before; and the items
# that took the most step time. No model runs. The retro job writes it to
# <flow home>/reports/graph-<date>.md and hands it to the retro. FLOW_NOW (an ISO time) stands
# in for the clock, for tests.
. "$(dirname "$0")/../lib/flow.sh"
DEFAULT_DAYS=7
days="$DEFAULT_DAYS"
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || die "usage: graph-report.sh [--days N]" 2; days="$2"; shift 2 ;;
    *) die "usage: graph-report.sh [--days N]" 2 ;;
  esac
done
case "$days" in ''|*[!0-9]*|0) die "--days takes a whole number from 1, not $days" 2 ;; esac
python3 -I "$FLOW_PLUGIN/scripts/_graph_report.py" "$(flow_home)/log" "$days" "${FLOW_NOW:-$(now_iso)}"

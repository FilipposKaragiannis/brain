"""The graph report: what each step of the flow cost over a period, from the run log.

  _graph_report.py <log dir> <days> <now> [markdown|json|keep]

Prints Markdown for the <days> before <now> (an ISO time). It opens with the verdict, "In short":
the steps that got slower, the steps an item goes through twice or more, the steps with failed
runs and the item that took the most time, or that nothing stands out. Then the numbers behind
it: per step the runs, the median time, the time nine runs in ten finish within, the failed runs,
the cost and the runs per item; the steps whose median grew against the period before; and the
items that took the most step time. No model runs: the retro job hands the report to the retro,
and the owner reads it as it is.

Every call first keeps the history of the steps (_step_history.py), which outlives the cut of the
run log. `keep` does only that and prints nothing (the job that cuts the log calls it first).
`json` prints {days, now, markdown, daily}: the report, and the daily lines of the last 30 days,
the days not yet settled counted from the records.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _step_history import NINE_IN_TEN, SECONDS_PER_DAY, daily_history, epoch, failed_count, keep_history, median, within  # noqa: E402

SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
SLOWER_FACTOR = 1.5
SLOWER_BY_SECONDS = 60
RUNS_TO_COMPARE = 3
REPEATED_RUNS_PER_ITEM = 2.0
ITEMS_LISTED = 5
OUTPUTS = ("markdown", "json", "keep")


def duration(seconds):
    seconds = int(seconds)
    if seconds < SECONDS_PER_MINUTE:
        return "%ds" % seconds
    if seconds < SECONDS_PER_HOUR:
        return "%dm %02ds" % (seconds // SECONDS_PER_MINUTE, seconds % SECONDS_PER_MINUTE)
    return "%dh %02dm" % (seconds // SECONDS_PER_HOUR, seconds % SECONDS_PER_HOUR // SECONDS_PER_MINUTE)


def by_step(runs):
    grouped = {}
    for run in runs:
        grouped.setdefault(run["step"], []).append(run)
    return grouped


def runs_per_item(runs):
    return len(runs) / len({run["item"] for run in runs})


def step_rows(grouped):
    rows = []
    for step, runs in sorted(grouped.items(), key=lambda pair: -sum(run["seconds"] for run in pair[1])):
        times = [run["seconds"] for run in runs]
        rows.append("| %s | %d | %s | %s | %d | $%.2f | %.1f |" % (
            step, len(runs), duration(median(times)), duration(within(times, NINE_IN_TEN)),
            failed_count(runs), sum(run["cost"] for run in runs), runs_per_item(runs)))
    return rows


def slower_steps(now_grouped, before_grouped):
    slower = []
    for step, runs in sorted(now_grouped.items()):
        earlier = before_grouped.get(step, [])
        if len(runs) < RUNS_TO_COMPARE or len(earlier) < RUNS_TO_COMPARE:
            continue
        now_median, before_median = median([run["seconds"] for run in runs]), median([run["seconds"] for run in earlier])
        if now_median >= before_median * SLOWER_FACTOR and now_median - before_median >= SLOWER_BY_SECONDS:
            slower.append({"step": step, "before": before_median, "now": now_median, "factor": now_median / max(before_median, 1)})
    return slower


def slower_lines(slower):
    return ["- %s: %s to %s at the median, %.1f times" % (
        step["step"], duration(step["before"]), duration(step["now"]), step["factor"]) for step in slower]


def ranked_items(runs):
    totals = {}
    for run in runs:
        total = totals.setdefault(run["item"], {"steps": 0, "seconds": 0, "cost": 0.0})
        total["steps"] += 1
        total["seconds"] += run["seconds"]
        total["cost"] += run["cost"]
    return sorted(totals.items(), key=lambda pair: -pair[1]["seconds"])


def item_rows(ranked):
    return ["| %s | %d | %s | $%.2f |" % (item, total["steps"], duration(total["seconds"]), total["cost"])
            for item, total in ranked[:ITEMS_LISTED]]


def findings(grouped, slower):
    lines = ["- **Slower:** %s takes %s at the median, up from %s. That is %.1f times slower." % (
        step["step"], duration(step["now"]), duration(step["before"]), step["factor"]) for step in slower]
    repeated = sorted(((runs_per_item(runs), step) for step, runs in grouped.items()
                       if runs_per_item(runs) >= REPEATED_RUNS_PER_ITEM), reverse=True)
    if repeated:
        lines.append("- **Repeated:** %s. A step that runs twice or more for one item is rework." % ", ".join(
            "%s ran %.1f times per item" % (step, rate) for rate, step in repeated))
    lines += ["- **Failed:** %d of %d %s runs failed." % (failed_count(runs), len(runs), step)
              for step, runs in sorted(grouped.items()) if failed_count(runs)]
    return lines


def in_short(grouped, slower, ranked):
    busiest, total = ranked[0]
    return (findings(grouped, slower) or ["- Nothing stands out: no step got slower, none ran twice or more per item, and no run failed."]) + [
        "- **Most time:** %s took %s over %d step run%s." % (busiest, duration(total["seconds"]), total["steps"], "" if total["steps"] == 1 else "s")]


def report(runs, days, now_timestamp):
    now = epoch(now_timestamp)
    period = days * SECONDS_PER_DAY
    this_period, before = [], []
    for run in runs:
        if now - period <= run["at"] < now:
            this_period.append(run)
        elif now - 2 * period <= run["at"] < now - period:
            before.append(run)
    lines = ["# Flow graph report", "",
             "The %d days before %s: %d step runs, %s of step time. The %d days before that: %d runs, %s." % (
                 days, now_timestamp, len(this_period), duration(sum(run["seconds"] for run in this_period)),
                 days, len(before), duration(sum(run["seconds"] for run in before)))]
    if not this_period:
        return lines + ["", "No step ran in this period."]
    grouped, ranked = by_step(this_period), ranked_items(this_period)
    slower = slower_steps(grouped, by_step(before))
    lines += ["", "## In short", ""] + in_short(grouped, slower, ranked)
    lines += ["", "## Steps", "", "| step | runs | median | nine in ten within | failed | cost | runs per item |", "|---|---|---|---|---|---|---|"]
    lines += step_rows(grouped)
    lines += ["", "## Slower than the period before", ""] + (slower_lines(slower) or ["No step's median grew by half or more."])
    lines += ["", "## Items that took the most step time", "", "| item | step runs | step time | cost |", "|---|---|---|---|"]
    lines += item_rows(ranked)
    return lines


def rendered(output, history, days, now_timestamp):
    if output == "keep":
        return ""
    markdown = "\n".join(report(history["runs"], days, now_timestamp))
    if output == "markdown":
        return markdown + "\n"
    return json.dumps({"days": days, "now": now_timestamp, "markdown": markdown,
                       "daily": daily_history(history["kept"], history["runs"], epoch(now_timestamp))}) + "\n"


def main(arguments):
    output = arguments[3] if len(arguments) == 4 else OUTPUTS[0]
    if len(arguments) not in (3, 4) or not arguments[1].isdigit() or int(arguments[1]) < 1 or output not in OUTPUTS:
        print("usage: _graph_report.py <log dir> <days> <now> [%s]" % "|".join(OUTPUTS), file=sys.stderr)
        return 2
    try:
        history = keep_history(arguments[0], epoch(arguments[2]))
        sys.stdout.write(rendered(output, history, int(arguments[1]), arguments[2]))
    except ValueError:
        print("flow: %s is no ISO time (2026-10-25T09:00:00Z)" % arguments[2], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

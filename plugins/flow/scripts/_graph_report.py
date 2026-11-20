"""The graph report: what each step of the flow cost over a period, from the run log.

  _graph_report.py <log dir> <days> <now>

Reads every step record of <log dir>/runs.1.jsonl and runs.jsonl (one JSON object per line with
item, step, at, seconds, exit and cost_usd; a line that is no such record is skipped) and prints
Markdown for the <days> before <now> (an ISO time): per step the runs, the median time, the time
nine runs in ten finish within, the failed runs, the cost and the runs per item; the steps whose
median grew against the period before; and the items that took the most step time. No model
runs: the retro job hands the report to the retro, and the owner reads it as it is.
"""
import calendar
import json
import math
import os
import sys
import time

SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 3600
SECONDS_PER_DAY = 86400
NINE_IN_TEN = 0.9
SLOWER_FACTOR = 1.5
SLOWER_BY_SECONDS = 60
RUNS_TO_COMPARE = 3
ITEMS_LISTED = 5
LOG_FILES = ("runs.1.jsonl", "runs.jsonl")
STEP_FIELDS = ("item", "step", "at", "seconds")


def epoch(timestamp):
    return calendar.timegm(time.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ"))


def duration(seconds):
    seconds = int(seconds)
    if seconds < SECONDS_PER_MINUTE:
        return "%ds" % seconds
    if seconds < SECONDS_PER_HOUR:
        return "%dm %02ds" % (seconds // SECONDS_PER_MINUTE, seconds % SECONDS_PER_MINUTE)
    return "%dh %02dm" % (seconds // SECONDS_PER_HOUR, seconds % SECONDS_PER_HOUR // SECONDS_PER_MINUTE)


def step_run(line):
    try:
        record = json.loads(line)
        if not isinstance(record, dict) or any(field not in record for field in STEP_FIELDS):
            return None
        return {"item": str(record["item"]), "step": str(record["step"]), "at": epoch(record["at"]),
                "seconds": int(record["seconds"]), "failed": record.get("exit", 0) != 0,
                "cost": float(record.get("cost_usd") or 0)}
    except (ValueError, TypeError, OverflowError):
        return None


def step_runs(log):
    for name in LOG_FILES:
        path = os.path.join(log, name)
        lines = open(path, encoding="utf-8", errors="replace") if os.path.exists(path) else []
        yield from filter(None, map(step_run, lines))


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def within(values, share):
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * share) - 1]


def by_step(runs):
    grouped = {}
    for run in runs:
        grouped.setdefault(run["step"], []).append(run)
    return grouped


def step_rows(grouped):
    rows = []
    for step, runs in sorted(grouped.items(), key=lambda pair: -sum(run["seconds"] for run in pair[1])):
        times = [run["seconds"] for run in runs]
        items = {run["item"] for run in runs}
        rows.append("| %s | %d | %s | %s | %d | $%.2f | %.1f |" % (
            step, len(runs), duration(median(times)), duration(within(times, NINE_IN_TEN)),
            sum(1 for run in runs if run["failed"]), sum(run["cost"] for run in runs), len(runs) / len(items)))
    return rows


def slower_lines(now_grouped, before_grouped):
    lines = []
    for step, runs in sorted(now_grouped.items()):
        earlier = before_grouped.get(step, [])
        if len(runs) < RUNS_TO_COMPARE or len(earlier) < RUNS_TO_COMPARE:
            continue
        now_median, before_median = median([run["seconds"] for run in runs]), median([run["seconds"] for run in earlier])
        if now_median >= before_median * SLOWER_FACTOR and now_median - before_median >= SLOWER_BY_SECONDS:
            lines.append("- %s: %s to %s at the median, %.1f times" % (
                step, duration(before_median), duration(now_median), now_median / max(before_median, 1)))
    return lines


def item_rows(runs):
    totals = {}
    for run in runs:
        total = totals.setdefault(run["item"], {"steps": 0, "seconds": 0, "cost": 0.0})
        total["steps"] += 1
        total["seconds"] += run["seconds"]
        total["cost"] += run["cost"]
    ranked = sorted(totals.items(), key=lambda pair: -pair[1]["seconds"])[:ITEMS_LISTED]
    return ["| %s | %d | %s | $%.2f |" % (item, total["steps"], duration(total["seconds"]), total["cost"]) for item, total in ranked]


def report(log, days, now_timestamp):
    now = epoch(now_timestamp)
    period = days * SECONDS_PER_DAY
    this_period, before = [], []
    for run in step_runs(log):
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
    lines += ["", "## Steps", "", "| step | runs | median | nine in ten within | failed | cost | runs per item |", "|---|---|---|---|---|---|---|"]
    lines += step_rows(by_step(this_period))
    slower = slower_lines(by_step(this_period), by_step(before))
    lines += ["", "## Slower than the period before", ""] + (slower or ["No step's median grew by half or more."])
    lines += ["", "## Items that took the most step time", "", "| item | step runs | step time | cost |", "|---|---|---|---|"]
    lines += item_rows(this_period)
    return lines


def main(arguments):
    if len(arguments) != 3 or not arguments[1].isdigit() or int(arguments[1]) < 1:
        print("usage: _graph_report.py <log dir> <days> <now>", file=sys.stderr)
        return 2
    try:
        print("\n".join(report(arguments[0], int(arguments[1]), arguments[2])))
    except ValueError:
        print("flow: %s is no ISO time (2026-10-25T09:00:00Z)" % arguments[2], file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

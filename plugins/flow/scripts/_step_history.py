"""The history of the steps: what each step of the flow did, day by day, kept past the run log.

The run log (<log dir>/runs.1.jsonl and runs.jsonl) is cut at 4000 lines, so keep_history keeps
what a chart of the steps is drawn from, under one lock (steps.daily.lock), so two calls at once
never write a day twice:
- <log dir>/steps.daily.jsonl gets one line per day (UTC) and step, with its runs, total and
  median seconds, nine-in-ten time, failed runs, cost and items, once the day is settled: a full
  day after it ended, because a run is recorded under the time it started and may end after
  midnight. A day already kept is never written again.
- <log dir>/steps.pending.jsonl holds the step records of the days not yet settled that sit in
  the older log file, the one the next cut drops, so a day's runs survive any number of cuts
  until the day is kept.
A step record is one JSON object per line with item, step, at, seconds, exit and cost_usd; a line
that is no such record is skipped. The records of both log files and the pending file count,
each once. Imported by _graph_report.py, which calls keep_history before every report, and
read_history, which writes nothing, for the slower steps alone.
"""
import calendar
import fcntl
import json
import math
import os
import time

SECONDS_PER_DAY = 86400
NINE_IN_TEN = 0.9
HISTORY_DAYS = 30
SETTLE_DAYS = 1
OLDER_LOG_FILE = "runs.1.jsonl"
LOG_FILES = (OLDER_LOG_FILE, "runs.jsonl")
HISTORY_FILE = "steps.daily.jsonl"
PENDING_FILE = "steps.pending.jsonl"
LOCK_FILE = "steps.daily.lock"
DAILY_FIELDS = ("day", "step", "runs", "seconds", "median", "within", "failed", "cost", "items")
STEP_FIELDS = ("item", "step", "at", "seconds")


def epoch(timestamp):
    return calendar.timegm(time.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ"))


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


def lines_of(log, name):
    path = os.path.join(log, name)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8", errors="replace") as source:
        return [line.rstrip("\n") for line in source]


def recorded_steps(log, names):
    recorded = {}
    for name in names:
        for line in lines_of(log, name):
            if line not in recorded:
                run = step_run(line)
                if run is not None:
                    recorded[line] = run
    return recorded


def median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def within(values, share):
    ordered = sorted(values)
    return ordered[math.ceil(len(ordered) * share) - 1]


def failed_count(runs):
    return sum(1 for run in runs if run["failed"])


def day_of(moment):
    return time.strftime("%Y-%m-%d", time.gmtime(moment))


def daily_lines(runs):
    grouped = {}
    for run in runs:
        grouped.setdefault((day_of(run["at"]), run["step"]), []).append(run)
    lines = []
    for (day, step), group in sorted(grouped.items()):
        times = [run["seconds"] for run in group]
        lines.append({"day": day, "step": step, "runs": len(group), "seconds": sum(times), "median": int(median(times)),
                      "within": int(within(times, NINE_IN_TEN)), "failed": failed_count(group),
                      "cost": round(sum(run["cost"] for run in group), 2), "items": len({run["item"] for run in group})})
    return lines


def kept_line(text):
    try:
        line = json.loads(text)
        return line if isinstance(line, dict) and all(field in line for field in DAILY_FIELDS) else None
    except ValueError:
        return None


def kept_history(log):
    kept = {}
    for line in filter(None, map(kept_line, lines_of(log, HISTORY_FILE))):
        kept.setdefault((line["day"], line["step"]), line)
    return list(kept.values())


def settled(day, now):
    return day < day_of(now - SETTLE_DAYS * SECONDS_PER_DAY)


def write_settled_days(log, runs, kept, now):
    kept_days = {line["day"] for line in kept}
    settled_now = [line for line in daily_lines(runs) if settled(line["day"], now) and line["day"] not in kept_days]
    if settled_now:
        with open(os.path.join(log, HISTORY_FILE), "a", encoding="utf-8") as history:
            history.write("".join(json.dumps(line, separators=(",", ":")) + "\n" for line in settled_now))
    return settled_now


def write_pending_records(log, now):
    leaving = recorded_steps(log, (PENDING_FILE, OLDER_LOG_FILE))
    pending = [line for line, run in leaving.items() if not settled(day_of(run["at"]), now)]
    if pending == lines_of(log, PENDING_FILE):
        return
    rewritten = os.path.join(log, "%s.%d" % (PENDING_FILE, os.getpid()))
    with open(rewritten, "w", encoding="utf-8") as pending_file:
        pending_file.write("".join(line + "\n" for line in pending))
    os.replace(rewritten, os.path.join(log, PENDING_FILE))


def recorded_runs(log):
    return list(recorded_steps(log, (PENDING_FILE,) + LOG_FILES).values())


def keep_history(log, now):
    if not os.path.isdir(log):
        return {"kept": [], "runs": []}
    with open(os.path.join(log, LOCK_FILE), "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        runs = recorded_runs(log)
        kept = kept_history(log)
        kept += write_settled_days(log, runs, kept, now)
        write_pending_records(log, now)
    return {"kept": kept, "runs": runs}


def read_history(log):
    if not os.path.isdir(log):
        return {"kept": [], "runs": []}
    return {"kept": kept_history(log), "runs": recorded_runs(log)}


def daily_history(kept, runs, now):
    unsettled = [line for line in daily_lines(runs) if not settled(line["day"], now)]
    first_day = day_of(now - HISTORY_DAYS * SECONDS_PER_DAY)
    return sorted((line for line in kept + unsettled if line["day"] > first_day), key=lambda line: (line["day"], line["step"]))

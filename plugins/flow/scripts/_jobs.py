"""The scheduled jobs on this machine, read side. See scripts/jobs.sh.

  _jobs.py status <log dir> <launch agents dir> <prefix> [--json] <job>=<schedule>...
  _jobs.py history <log dir> <job> <n>
  _jobs.py plist <label> <dir> <command> <schedule> <log> <path>
  _jobs.py cron <schedule> <dir> <command> <log>
  _jobs.py args <schedule>

A schedule is "every 30m [args]", "every 2h [args]", "daily 02:00 [args]" or
"weekly sun 03:00 [args]"; args prints its args checked and shell-quoted. The runs come from
<log dir>/runs.1.jsonl and runs.jsonl, one line per run that the job library writes; launchd
adds whether the job is loaded and its own run count. Times print in local time."""
import calendar, json, os, re, subprocess, sys, time
from datetime import datetime, timedelta
from xml.sax.saxutils import escape

DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
WEEK = 7 * 86400
# The args go into a shell command, so each is one plain option or value: no spaces, quotes,
# globs, redirections or substitutions.
ARG = re.compile(r"[A-Za-z0-9_./:=@%+,-]+")


# parse: the schedule as a dict, or ValueError naming what is wrong with it.
def parse(spec):
    words = spec.split()
    s = None
    if len(words) >= 2 and words[0] == "every":
        m = re.fullmatch(r"(\d+)([mh])", words[1])
        if m and int(m.group(1)) > 0:
            s = {"every": int(m.group(1)) * (60 if m.group(2) == "m" else 3600), "args": words[2:]}
    if len(words) >= 2 and words[0] == "daily":
        s = clock(spec, words[1], {"args": words[2:]})
    if len(words) >= 3 and words[0] == "weekly" and words[1][:3].lower() in DAYS:
        s = clock(spec, words[2], {"weekday": DAYS.index(words[1][:3].lower()), "args": words[3:]})
    if s is None:
        raise ValueError("cannot read the schedule %r: use every 30m, daily 02:00 or weekly sun 03:00" % spec)
    for a in s["args"]:
        if not ARG.fullmatch(a):
            raise ValueError("the schedule %r has the arg %r: an arg is one option or value of letters, digits and _./:=@%%+,-" % (spec, a))
    return s


def clock(spec, at, s):
    m = re.fullmatch(r"(\d\d):(\d\d)", at)
    if not m:
        return None
    if int(m.group(1)) > 23 or int(m.group(2)) > 59:
        raise ValueError("the schedule %r has no time %s: the hour is 00-23, the minute 00-59" % (spec, at))
    return dict(s, hour=int(m.group(1)), minute=int(m.group(2)))


def read(spec):
    try:
        return parse(spec)
    except ValueError as e:
        sys.exit("flow: %s" % e)


def when(s):
    if "every" in s:
        n = s["every"]
        return "every %dh" % (n // 3600) if n % 3600 == 0 else "every %dm" % (n // 60)
    at = "%02d:%02d" % (s["hour"], s["minute"])
    return "weekly %s %s" % (DAYS[s["weekday"]], at) if "weekday" in s else "daily " + at


def next_calendar(s, now):
    t = now.replace(hour=s["hour"], minute=s["minute"], second=0, microsecond=0)
    if "weekday" in s:
        t += timedelta(days=(s["weekday"] - t.weekday()) % 7)
        return t if t > now else t + timedelta(days=7)
    return t if t > now else t + timedelta(days=1)


def runs(log, base=None):
    out = []
    for path in (os.path.join(log, "runs.1.jsonl"), os.path.join(log, "runs.jsonl")):
        for line in open(path) if os.path.exists(path) else []:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if base is None or r.get("job") == base or re.fullmatch(re.escape(base) + r"-\d+", r.get("job", "")):
                out.append(r)
    return out


def epoch(iso):
    return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")) if iso else 0


def outcome(r):
    # str(): a record before 1.20.2 holds a result of digits as a number.
    text = str(r.get("result", ""))
    if text.startswith("paused"):
        return "paused"
    if text.startswith("skipped"):
        return "skipped"
    if r.get("exit", 0) != 0 or text.startswith("error") or text.startswith("stopped: no step ran"):
        return "failed"
    if text.startswith("quiet"):
        return "quiet"
    if "gate" in text:
        return "gate"
    return "work"


def local(ts):
    return datetime.fromtimestamp(ts).strftime("%b %d %H:%M")


def took(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return "%ds" % seconds
    if seconds < 3600:
        return "%dm %02ds" % (seconds // 60, seconds % 60)
    return "%dh %02dm" % (seconds // 3600, seconds % 3600 // 60)


# alive: the pid still runs jobs/<base>.sh. A lock left by a restart can name a reused pid.
def alive(pid, base):
    if not pid.isdigit():
        return False
    try:
        p = subprocess.run(["ps", "-o", "command=", "-p", pid], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return p.returncode == 0 and ("jobs/%s.sh" % base) in p.stdout


def running(log, base):
    out = []
    for name in sorted(os.listdir(log)) if os.path.isdir(log) else []:
        m = re.fullmatch(re.escape(base) + r"(-\d+)?\.lock", name)
        if not m:
            continue
        d = os.path.join(log, name)
        pid = open(os.path.join(d, "pid")).read().strip() if os.path.exists(os.path.join(d, "pid")) else ""
        at = open(os.path.join(d, "at")).read().strip() if os.path.exists(os.path.join(d, "at")) else ""
        if alive(pid, base):
            out.append({"job": name[:-5], "pid": int(pid), "at": at})
    return out


def launchd(label):
    try:
        p = subprocess.run(["launchctl", "print", "gui/%d/%s" % (os.getuid(), label)],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    info = {}
    for key, pattern in (("runs", r"^\s*runs = (\d+)"), ("last_exit", r"^\s*last exit code = (.+)$")):
        m = re.search(pattern, p.stdout, re.M)
        if m:
            info[key] = int(m.group(1)) if m.group(1).isdigit() else m.group(1).strip()
    return info


def job_status(log, agents, prefix, name, spec, now):
    label = "%s.%s" % (prefix, name)
    try:
        s, error = (parse(spec) if spec else None), ""
    except ValueError as e:
        s, error = None, str(e)
    row = {"job": name, "label": label, "schedule": when(s) if s else "",
           "args": " ".join(s["args"]) if s else "",
           "installed": os.path.exists(os.path.join(agents, label + ".plist")),
           "paused": os.path.exists(os.path.join(log, name + ".paused")),
           "running": running(log, name)}
    info = launchd(label) if row["installed"] else None
    row["loaded"] = info is not None
    row["launchd"] = info or {}
    history = runs(log, name)
    row["runs"] = len(history)
    week = [r for r in history if epoch(r.get("at")) > now - WEEK]
    row["week"] = {k: sum(1 for r in week if outcome(r) == k) for k in ("work", "gate", "quiet", "skipped", "paused", "failed")}
    done = [r for r in history if outcome(r) not in ("skipped", "paused")]
    row["last"] = dict(done[-1], outcome=outcome(done[-1])) if done else None
    if error:
        row["error"] = error
    row["next"] = next_run(s, row, history, now)
    return row


def next_run(s, row, history, now):
    if row.get("error"):
        return "fix the schedule"
    if not s:
        return "no schedule"
    if row["paused"]:
        return "paused"
    if not row["loaded"]:
        return "not scheduled"
    if "every" in s:
        last = max((epoch(r.get("at")) for r in history), default=0)
        if not last:
            return "within %s" % when(s)[6:]
        due = last + s["every"]
        return local(due) if due > now else "due"
    return next_calendar(s, datetime.fromtimestamp(now)).strftime("%b %d %H:%M")


def state(row, now):
    if row["running"]:
        since = min(epoch(r["at"]) for r in row["running"] if r["at"]) if any(r["at"] for r in row["running"]) else now
        who = ", ".join(r["job"] for r in row["running"]) if len(row["running"]) > 1 or row["running"][0]["job"] != row["job"] else ""
        return "running %s%s" % (took(now - since), " (%s)" % who if who else "")
    if row["paused"]:
        return "paused"
    if not row["installed"]:
        return "not installed"
    return "scheduled" if row["loaded"] else "not loaded"


def status(log, agents, prefix, as_json, pairs):
    now = time.time()
    rows = [job_status(log, agents, prefix, name, spec, now) for name, spec in pairs]
    if as_json:
        print(json.dumps(rows, indent=1))
        return
    print("| Job | Schedule | State | Last run | Took | Result | Next run | Last 7 days |")
    print("|---|---|---|---|---|---|---|---|")
    for r in rows:
        last = r["last"]
        week = ", ".join("%d %s" % (v, k) for k, v in r["week"].items() if v) or "none"
        print("| %s | %s | %s | %s | %s | %s | %s | %s |" % (
            r["job"], schedule_cell(r), state(r, now),
            local(epoch(last["at"])) if last else "never", took(last["seconds"]) if last else "",
            cell(last) if last else "", r["next"], week))


def schedule_cell(r):
    if r.get("error"):
        return "error: " + r["error"].replace("|", "/")
    return (r["schedule"] + (" `%s`" % r["args"] if r["args"] else "")) or "none"


def cell(r):
    text = str(r.get("result", "")).replace("|", "/")
    text = text if len(text) <= 70 else text[:67] + "..."
    return "%s%s: %s" % (r["outcome"], " (%s)" % r["job"] if "-" in r.get("job", "") else "", text)


def history(log, base, n):
    rows = runs(log, base)[-n:]
    if not rows:
        print("No runs of %s yet." % base)
        return
    print("| Start | Run | Took | Exit | Outcome | Said |")
    print("|---|---|---|---|---|---|")
    for r in reversed(rows):
        print("| %s | %s | %s | %s | %s | %s |" % (local(epoch(r.get("at"))), r.get("job", ""), took(r.get("seconds", 0)),
                                             r.get("exit", ""), outcome(r), str(r.get("result", "")).replace("|", "/")))


def plist(label, workdir, command, spec, log, path):
    s = read(spec)
    if "every" in s:
        timing = "  <key>StartInterval</key><integer>%d</integer>\n" % s["every"]
    else:
        cal = "<key>Hour</key><integer>%d</integer><key>Minute</key><integer>%d</integer>" % (s["hour"], s["minute"])
        if "weekday" in s:
            cal += "<key>Weekday</key><integer>%d</integer>" % ((s["weekday"] + 1) % 7)
        timing = "  <key>StartCalendarInterval</key><dict>%s</dict>\n" % cal
    run = "cd %s && %s" % (sh(workdir), command)
    print('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>-lc</string><string>%s</string></array>
%s  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>%s</string></dict>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>''' % (escape(label), escape(run), timing, escape(path), escape(log), escape(log)))


def sh(text):
    return text if re.fullmatch(r"[A-Za-z0-9_./-]+", text) else "'" + text.replace("'", "'\\''") + "'"


def cron(spec, workdir, command, log):
    s = read(spec)
    if "every" in s:
        n = s["every"] // 60
        # */n restarts at each hour or day, so only a step that divides it evenly is a steady interval.
        if (n < 60 and 60 % n) or (n >= 60 and (n % 60 or 24 % (n // 60))):
            sys.exit("flow: cron cannot run %s steadily: use minutes that divide 60 (1-6, 10, 12, 15, 20, 30m)"
                     " or hours that divide 24 (1-4, 6, 8, 12, 24h); launchd takes any interval" % when(s))
        timing = "*/%d * * * *" % n if n < 60 else "0 */%d * * *" % (n // 60)
    else:
        timing = "%d %d * * %s" % (s["minute"], s["hour"], (s["weekday"] + 1) % 7 if "weekday" in s else "*")
    run = "cd %s && %s >> %s 2>&1" % (sh(workdir), command, sh(log))
    print("%s %s" % (timing, run.replace("%", "\\%")))


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command == "status":
        as_json = "--json" in args
        args = [a for a in args if a != "--json"]
        status(args[0], args[1], args[2], as_json, [tuple(a.split("=", 1)) for a in args[3:]])
    elif command == "history":
        history(args[0], args[1], int(args[2]))
    elif command == "plist":
        plist(*args)
    elif command == "cron":
        cron(*args)
    elif command == "args":
        print(" ".join(sh(a) for a in read(args[0])["args"]))
    else:
        sys.exit("flow: unknown command %s" % command)


main()

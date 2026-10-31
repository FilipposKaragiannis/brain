"""Pool health, read side. See scripts/steward.sh health and scripts/board.sh.

  _health.py procs
  _health.py alive <procs file> <item> <worktree> [<pid>]
  _health.py owner
  _health.py activity <worktree> <reports dir> <events.log> <item>
  _health.py runs <runs dir> <procs file> <grace seconds>
  _health.py last-next <log dir>
  _health.py next-streaks <log dir>
  _health.py epoch <iso time>
  _health.py seconds <config key> <duration>
  _health.py ago <epoch>
  _health.py spawn <log> <command>...
  _health.py review <state json> <review rows file> [<record path>]

procs prints one line per process: pid, working directory (agent processes only) and command,
tab separated, and fails when ps lists nothing, so a missing ps never reads as every run dead. A
run is alive when the pid its record names still runs an agent or the unattended loop, or when
any other process is an agent working in the worktree, or an agent or the loop names the worktree
or the item in its command line. An editor, a tail or the claude daemon naming the worktree is
not a run. A run record carries no pid when an older flow wrote it; the scan
covers it. Times print in local time.

review judges a PR waiting at the merge gate from comments.sh state (GitHub's review decision,
latest reviews and pending review requests) and comments.sh reviews (the flow's own requests, one
JSON row per reviewer). It prints `state<TAB>changes-requested|in-review|ready`, then
`waiting<TAB><reviewers>` when a reviewer has not answered, then one `cannot<TAB><reviewer><TAB>
<reply>` per reviewer that replied it cannot review. Changes requested wins; a pending request or
an unanswered flow request is in review. A required approval alone is not: at the merge gate
that approval is the owner's. With a record path it also writes {pr, state, waiting, cannot, at}
there as JSON, for the console."""
import calendar, glob, json, os, re, subprocess, sys, time

AGENT = re.compile(r"(^|/)(claude|codex)$")
SERVICE = {"daemon", "mcp"}
LOOP = re.compile(r"run-unattended\.sh|jobs/(next|comments)\.sh")
DURATION = re.compile(r"(\d+)([smhd]?)")
UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "": 60}


def is_agent(command):
    words = command.split()
    return bool(words) and bool(AGENT.search(words[0])) and (len(words) < 2 or words[1] not in SERVICE)


def is_host(command):
    return is_agent(command) or bool(LOOP.search(command))


def run(args):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return p.stdout


def epoch(iso):
    try:
        return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return 0


def cwds(pids):
    out = {}
    if not pids:
        return out
    if os.path.isdir("/proc/self"):
        for pid in pids:
            try:
                out[pid] = os.readlink("/proc/%s/cwd" % pid)
            except OSError:
                pass
        return out
    pid = None
    for line in run(["lsof", "-a", "-d", "cwd", "-Fpn", "-p", ",".join(pids)]).splitlines():
        if line.startswith("p"):
            pid = line[1:]
        elif line.startswith("n") and pid:
            out[pid] = line[1:]
    return out


def procs():
    rows = []
    for line in run(["ps", "-axww", "-o", "pid=,command="]).splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            rows.append((parts[0], parts[1].replace("\t", " ")))
    if not rows:
        sys.exit("flow: ps listed no processes")
    where = cwds([pid for pid, command in rows if is_host(command)])
    for pid, command in rows:
        print("%s\t%s\t%s" % (pid, where.get(pid, ""), command))


def snapshot(path):
    rows = []
    for line in open(path) if os.path.exists(path) else []:
        parts = line.rstrip("\n").split("\t", 2)
        if len(parts) == 3:
            rows.append(parts)
    return rows


def ancestors():
    found, pid = set(), os.getpid()
    while pid > 1 and pid not in found:
        found.add(pid)
        out = run(["ps", "-o", "ppid=", "-p", str(pid)]).strip()
        pid = int(out) if out.isdigit() else 0
    return found


def alive(rows, item, worktree, pid):
    own = ancestors()
    for number, _, command in rows:
        if number == pid and is_host(command):
            return "pid %s" % number
    wts = {worktree.rstrip("/"), os.path.realpath(worktree)}
    named = re.compile("|".join(re.escape(w) for w in sorted(wts)) + r"(?![A-Za-z0-9_-])(?!\.[A-Za-z0-9])")
    for number, where, command in rows:
        if int(number) in own:
            continue
        real = os.path.realpath(where) if where else ""
        if is_agent(command) and any(real == w or real.startswith(w + "/") for w in wts):
            return "process %s" % number
        if is_host(command) and (named.search(command) or item in command.split()):
            return "process %s" % number
    return ""


def owner():
    pid = os.getppid()
    seen = set()
    while pid > 1 and pid not in seen:
        seen.add(pid)
        out = run(["ps", "-o", "ppid=,command=", "-p", str(pid)]).strip().split(None, 1)
        if len(out) < 2:
            return ""
        if is_host(out[1]):
            return str(pid)
        pid = int(out[0]) if out[0].isdigit() else 0
    return ""


def newest(paths):
    best = 0
    for path in paths:
        try:
            best = max(best, int(os.stat(path).st_mtime))
        except OSError:
            pass
    return best


def activity(worktree, reports, events, item):
    changed = run(["git", "-C", worktree, "status", "--porcelain", "-z", "--", ".", ":!.flow"])
    names, entries = [], iter(changed.split("\0"))
    for entry in entries:
        if len(entry) > 3:
            names.append(os.path.join(worktree, entry[3:]))
            if entry[0] in "RC":
                names.append(os.path.join(worktree, next(entries, "")))
    best = newest(names)
    for root, _, files in os.walk(reports):
        best = max(best, newest([os.path.join(root, f) for f in files]), newest([root]))
    for line in open(events) if os.path.exists(events) else []:
        parts = line.split("\t")
        if len(parts) >= 3 and parts[1] == item and parts[2] != "health":
            best = max(best, epoch(parts[0]))
    return best


def age(then):
    seconds = max(0, int(time.time()) - then)
    if seconds < 3600:
        return "%dm" % (seconds // 60)
    if seconds < 86400:
        return "%dh %02dm" % (seconds // 3600, seconds % 3600 // 60)
    return "%dd %dh" % (seconds // 86400, seconds % 86400 // 3600)


def ago(then):
    return age(then) + " ago" if then else "never"


def seconds(key, text):
    m = DURATION.fullmatch(text.strip())
    if not m:
        sys.exit("flow: %s is %r: use a number with s, m, h or d, like 10m or 24h" % (key, text))
    return int(m.group(1)) * UNITS[m.group(2)]


def runs(directory, path, grace):
    rows, now, out = snapshot(path), int(time.time()), []
    for f in sorted(glob.glob(os.path.join(directory, "*.json"))):
        try:
            record = json.load(open(f))
        except ValueError:
            continue
        how = alive(rows, record.get("item", ""), record.get("worktree", ""), str(record.get("pid", "")))
        started = epoch(record.get("started"))
        record.update(alive=bool(how), age=now - started if started else 0)
        record["starting"] = not how and record["age"] <= grace
        out.append(record)
    print(json.dumps(out))


def last_next(log):
    result = ""
    for r in next_runs(log):
        result = r["result"]
    print(result)


def next_runs(log):
    """The next job's records, oldest first, with job and result as strings; a line that is not a
    record is skipped (a record before 1.20.2 may hold a result of digits as a number)."""
    for name in ("runs.1.jsonl", "runs.jsonl"):
        path = os.path.join(log, name)
        for line in open(path) if os.path.exists(path) else []:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not isinstance(r, dict):
                continue
            job = r.get("job")
            if isinstance(job, str) and re.fullmatch(r"next(-\d+)?", job):
                yield {**r, "job": job, "result": str(r.get("result") or "")}


def next_streaks(log):
    """For each next worker, how its last runs in a row ended, when they ended the same way: one
    line per worker, job, kind and count, tab separated. The kinds: lock (the worker waited out the
    pick lock) and nostep (the run ended as if done without one step). A paused or skipped run is
    not a run and does not break a streak."""
    last = {}
    for r in next_runs(log):
        text = r["result"]
        if text.startswith(("skipped", "paused")):
            continue
        kind = "lock" if "held the pick" in text else "nostep" if text.startswith("stopped: no step ran") else ""
        job = r["job"]
        streak = last.get(job)
        if kind and streak and streak[0] == kind:
            last[job] = (kind, streak[1] + 1, text)
        else:
            last[job] = (kind, 1, text)
    for job in sorted(last):
        kind, n, text = last[job]
        if kind:
            print("%s\t%s\t%d\t%s" % (job, kind, n, text))


def spawn(log, command):
    with open(log, "ab") as out:
        p = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    print(p.pid)


def review(state, rows, record=None):
    decision = state.get("reviewDecision") or ""
    latest = [r.get("state") for r in state.get("latestReviews") or []]
    # GitHub tracks a Copilot request in reviewRequests, and its timeline misses a removed request,
    # so only the reviewers asked by mention count here as waiting.
    waiting = [r["reviewer"] for r in rows if not r.get("answered") and r["reviewer"] != "copilot"]
    cannot = [(r["reviewer"], r["cannot"]) for r in rows if r.get("cannot")]
    if decision == "CHANGES_REQUESTED" or (not decision and "CHANGES_REQUESTED" in latest):
        verdict = "changes-requested"
    elif state.get("reviewRequests") or waiting:
        verdict = "in-review"
    else:
        verdict = "ready"
    print("state\t%s" % verdict)
    if waiting:
        print("waiting\t%s" % " ".join(waiting))
    for reviewer, said in cannot:
        print("cannot\t%s\t%s" % (reviewer, said.replace("\t", " ")))
    if record:
        out = {"pr": state.get("number"), "url": state.get("url", ""), "state": verdict, "waiting": waiting,
               "cannot": [{"reviewer": reviewer, "said": said} for reviewer, said in cannot],
               "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        with open(record + ".tmp", "w") as f:
            json.dump(out, f)
        os.replace(record + ".tmp", record)


def main():
    command, args = sys.argv[1], sys.argv[2:]
    if command == "procs":
        procs()
    elif command == "alive":
        print(alive(snapshot(args[0]), args[1], args[2], args[3] if len(args) > 3 else ""))
    elif command == "owner":
        print(owner())
    elif command == "activity":
        print(activity(*args))
    elif command == "runs":
        runs(args[0], args[1], int(args[2]))
    elif command == "last-next":
        last_next(args[0])
    elif command == "next-streaks":
        next_streaks(args[0])
    elif command == "epoch":
        print(epoch(args[0]))
    elif command == "seconds":
        print(seconds(*args))
    elif command == "ago":
        print(ago(int(args[0])))
    elif command == "review":
        rows = [json.loads(line) for line in open(args[1]) if line.strip()]
        review(json.loads(args[0]), rows, args[2] if len(args) > 2 else None)
    elif command == "spawn":
        spawn(args[0], args[1:])
    else:
        sys.exit("flow: unknown command %s" % command)


main()

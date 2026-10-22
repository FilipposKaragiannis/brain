"""Pool health, read side. See scripts/steward.sh health and scripts/board.sh.

  _health.py procs
  _health.py alive <procs file> <item> <worktree> [<pid>]
  _health.py owner
  _health.py activity <worktree> <reports dir> <events.log> <item>
  _health.py runs <runs dir> <procs file> <grace seconds>
  _health.py last-next <log dir>
  _health.py epoch <iso time>
  _health.py seconds <config key> <duration>
  _health.py ago <epoch>
  _health.py spawn <log> <command>...

procs prints one line per process: pid, working directory (agent processes only) and command,
tab separated. A run is alive when the pid its record names still runs an agent or the unattended
loop, or when any other process is an agent working in the worktree, or names the worktree or
the item in its command line. A run record carries no pid when an older flow wrote it; the scan
covers it. Times print in local time."""
import calendar, glob, json, os, re, subprocess, sys, time

AGENT = re.compile(r"(^|/)(claude|codex)$")
LOOP = re.compile(r"run-unattended\.sh|jobs/(next|comments)\.sh")
DURATION = re.compile(r"(\d+)([smhd]?)")
UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "": 60}


def is_agent(command):
    words = command.split()
    return bool(words) and bool(AGENT.search(words[0]))


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
        if named.search(command) or (item in command.split() and is_host(command)):
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
    names = []
    for entry in changed.split("\0"):
        if len(entry) > 3:
            names.append(os.path.join(worktree, entry[3:]))
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
    for name in ("runs.1.jsonl", "runs.jsonl"):
        path = os.path.join(log, name)
        for line in open(path) if os.path.exists(path) else []:
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if re.fullmatch(r"next(-\d+)?", r.get("job", "")):
                result = r.get("result", "")
    print(result)


def spawn(log, command):
    with open(log, "ab") as out:
        p = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    print(p.pid)


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
    elif command == "epoch":
        print(epoch(args[0]))
    elif command == "seconds":
        print(seconds(*args))
    elif command == "ago":
        print(ago(int(args[0])))
    elif command == "spawn":
        spawn(args[0], args[1:])
    else:
        sys.exit("flow: unknown command %s" % command)


main()

"""Pool health, read side. See scripts/steward.sh health and scripts/board.sh.

  _health.py procs
  _health.py alive <procs file> <item> <worktree> [<pid>]
  _health.py session <procs file> <pid>
  _health.py sessions <procs file> <stale seconds> <folder>...
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
or the item in its command line. An editor, a tail or a host's own server naming the worktree is
not a run: the claude daemon, an MCP server, and the Codex desktop app's app-server, its daemon
and exec-server, which keep the folder they were started in for days. Only the first two words
after the executable that are not options say so (`codex -c k=v app-server`), as the console
reads them. A run record carries no pid when an older flow wrote it; the scan covers it. Times
print in local time.

session names one process for a line a person reads: `claude process 62102, idle 3d 2h` (idle
since Claude last changed its status), `claude process 4242, busy`, or `codex process 7, running
7d 2h` when the host keeps no status. Claude writes ~/.claude/sessions/<pid>.json for each running
process (in $CLAUDE_CONFIG_DIR when set); it counts only when it names the pid and, when it says
so, the same start time, so a reused pid never reads an old status.

sessions lists the agents working in or under the given folders, one tab-separated line each:
pid, host, kind (agent for claude -p and codex exec, else session), the folder, state (busy, idle
or unknown), the seconds idle (or alive, when unknown), and stale (1 or 0). Idle at least the
stale seconds is stale; with no status, alive that long is; busy never is.

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
# A host's own servers, never an agent: the subcommand, the first word after the executable that is
# not an option (`codex app-server daemon pid-update-loop` is app-server's). Never an unattended run:
# `claude -p mcp is broken` or `codex exec daemon fails` is an agent whose prompt names a server.
SERVICE = {"daemon", "mcp", "app-server", "exec-server"}
OPTIONS_WITH_VALUE = {"-c", "--config"}
UNATTENDED = re.compile(r" (-p|--print|exec)( |$)")
LOOP = re.compile(r"run-unattended\.sh|jobs/(next|comments)\.sh")
DURATION = re.compile(r"(\d+)([smhd]?)")
UNITS = {"s": 1, "m": 60, "h": 3600, "d": 86400, "": 60}


# ps prints a command unquoted. The executable runs past a space only while the part beyond it is
# still an app bundle or the folder the Claude desktop app keeps its CLI in, as the console reads it.
PATH_WITH_SPACES = (".app/", "Application Support/")


def split_command(command):
    tokens = command.split()
    executable, index = (tokens[0] if tokens else ""), 1
    while index < len(tokens):
        extended = executable + " " + tokens[index]
        if not any(extended.rfind(m) >= 0 and extended.rfind(m) + len(m) > len(executable) + 1 for m in PATH_WITH_SPACES):
            break
        executable, index = extended, index + 1
    return [executable] + tokens[index:] if executable else []


def subcommand(words):
    index = 1
    while index < len(words):
        word = words[index]
        if not word.startswith("-"):
            return word
        index += 2 if word in OPTIONS_WITH_VALUE else 1
    return ""


def is_server(words):
    return subcommand(words) in SERVICE and not UNATTENDED.search(" ".join(words))


def is_agent(command):
    words = split_command(command)
    return bool(words) and bool(AGENT.search(words[0])) and not is_server(words)


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


def started(pids):
    """Per pid: how many seconds it has run, as ps says."""
    out = {}
    if not pids:
        return out
    for line in run(["ps", "-o", "pid=,etime=", "-p", ",".join(pids)]).splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit():
            out[parts[0]] = elapsed(parts[1])
    return out


def elapsed(text):
    days, _, clock = text.rpartition("-")
    parts = [int(p) for p in clock.split(":") if p.isdigit()][::-1]
    seconds = sum(p * u for p, u in zip(parts, (1, 60, 3600)))
    return seconds + (int(days) * 86400 if days.isdigit() else 0)


# ps on macOS dates a process that lived through a clock change an hour or two off, so the start
# Claude recorded only has to fall this near the one ps implies.
SAME_START_SLACK = 2 * 3600


def claude_status(pid, cwd, alive_for, now):
    """(busy|idle, since epoch) from ~/.claude/sessions/<pid>.json, or None when the file is
    missing or belongs to an earlier process with the same pid (another folder or start)."""
    home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    try:
        with open(os.path.join(home, "sessions", "%s.json" % pid)) as f:
            record = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(record, dict) or str(record.get("pid")) != str(pid):
        return None
    if cwd and isinstance(record.get("cwd"), str) and os.path.realpath(record["cwd"]) != os.path.realpath(cwd):
        return None
    began = record.get("startedAt")
    if isinstance(began, (int, float)) and not isinstance(began, bool) and alive_for:
        if abs(began // 1000 - (now - alive_for)) > SAME_START_SLACK:
            return None
    status, since = record.get("status"), record.get("statusUpdatedAt")
    if status not in ("busy", "idle") or not isinstance(since, (int, float)) or isinstance(since, bool):
        return None
    return status, int(since // 1000)


def host_name(command):
    words = split_command(command)
    return os.path.basename(words[0]) if words else "?"


def describe(pid, cwd, command, alive_for, now):
    """(busy|idle|unknown, seconds idle, or alive when unknown)."""
    status = claude_status(pid, cwd, alive_for, now) if host_name(command) == "claude" else None
    if status is None:
        return "unknown", alive_for
    state, since = status
    return state, max(0, now - since) if state == "idle" else 0


def session_line(rows, pid):
    row = next((r for r in rows if r[0] == pid), None)
    if row is None:
        return "process %s" % pid
    alive_for = started([pid]).get(pid)
    state, seconds = describe(pid, row[1], row[2], alive_for or 0, int(time.time()))
    named = "%s process %s" % (host_name(row[2]), pid)
    if state == "unknown" and alive_for is None:
        return named
    return named + ", " + {"busy": "busy", "idle": "idle " + age_of(seconds)}.get(state, "running " + age_of(seconds))


def sessions(rows, stale, folders):
    wts = [(f.rstrip("/"), os.path.realpath(f)) for f in folders]
    picked = []
    for number, where, command in rows:
        if not where or not is_agent(command):
            continue
        real = os.path.realpath(where)
        for given, resolved in wts:
            if real == resolved or real.startswith(resolved + "/"):
                picked.append((number, where, command, given))
                break
    ages, now = started([n for n, _, _, _ in picked]), int(time.time())
    for number, where, command, folder in picked:
        state, seconds = describe(number, where, command, ages.get(number, 0), now)
        is_stale = state != "busy" and seconds >= stale
        kind = "agent" if UNATTENDED.search(command) else "session"
        print("\t".join([number, host_name(command), kind, folder, state, str(seconds), "1" if is_stale else "0"]))


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


def age_of(seconds):
    return age(int(time.time()) - seconds)


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
    """The records of every next schedule and worker (next, next-2, next-codex, next-codex-2),
    oldest first, with job and result as strings; a line that is not a record is skipped (a record
    before 1.20.2 may hold a result of digits as a number)."""
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
            if isinstance(job, str) and re.fullmatch(r"next(-[a-z][a-z0-9]*)?(-\d+)?", job):
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
    elif command == "session":
        print(session_line(snapshot(args[0]), args[1]))
    elif command == "sessions":
        sessions(snapshot(args[0]), int(args[1]), args[2:])
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

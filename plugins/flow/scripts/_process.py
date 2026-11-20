"""Reading processes where ps may not run, for _health.py and _jobs.py. lib/process.sh does the
same for the shell scripts.

A shell exits 126 or 127 for a command it cannot run, and Python raises OSError: a sandbox refuses
the setuid /bin/ps on macOS. ps is then read through pgrep for the command lines and lsof (/proc
on Linux) for a parent, which need no privilege. pgrep -a lists the caller's own ancestors on
macOS, and the whole command line on Linux, where ps is no setuid program. A ps that ran and
failed or listed nothing is not refused: it reads as nothing, as before."""
import os, subprocess

SHELL_CANNOT_RUN = (126, 127)
LOOKUP_SECONDS = 30
# Between the processes pgrep lists: a command line can hold a newline, never this.
PGREP_SEPARATOR = "\x1e"


def lookup(args):
    """The command's output, empty when it fails to start or runs past the lookup seconds."""
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=LOOKUP_SECONDS).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def ps(args):
    """ps's output, or None when ps cannot be started."""
    try:
        finished = subprocess.run(["ps"] + args, capture_output=True, text=True, timeout=LOOKUP_SECONDS)
    except subprocess.TimeoutExpired:
        return ""
    except OSError:
        return None
    return None if finished.returncode in SHELL_CANNOT_RUN else finished.stdout


def rows(entries):
    found = []
    for entry in entries:
        parts = entry.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit():
            found.append((parts[0], " ".join(parts[1].split("\n")).replace("\t", " ")))
    return found


def pgrep_rows():
    return rows(lookup(["pgrep", "-alf", "-d", PGREP_SEPARATOR, "."]).split(PGREP_SEPARATOR))


def listing():
    """(pid, command) for every running process, from ps, else from pgrep."""
    listed = ps(["-axww", "-o", "pid=,command="])
    return pgrep_rows() if listed is None else rows(listed.splitlines())


def command_of(pid):
    """The process's command line, empty when none runs."""
    listed = ps(["-o", "command=", "-p", str(pid)])
    return dict(pgrep_rows()).get(str(pid), "") if listed is None else listed.strip()


def proc_parent(pid):
    """The parent pid /proc/<pid>/stat gives: its fourth field, after the name in parentheses."""
    try:
        with open("/proc/%s/stat" % pid) as stat:
            fields = stat.read().rpartition(")")[2].split()
    except OSError:
        return ""
    return fields[1] if len(fields) > 1 else ""


def lsof_parent(pid):
    lines = lookup(["lsof", "-a", "-d", "cwd", "-FR", "-p", str(pid)]).splitlines()
    return next((line[1:] for line in lines if line.startswith("R")), "")


def parent_of(pid):
    """The process's parent pid, 0 when it cannot be read: from ps, else from /proc or lsof."""
    listed = ps(["-o", "ppid=", "-p", str(pid)])
    if listed is None:
        listed = proc_parent(pid) if os.path.isdir("/proc/self") else lsof_parent(pid)
    listed = listed.strip()
    return int(listed) if listed.isdigit() else 0


def group_running(group):
    """True while a process of the process group runs: a zombie has ended. Where ps cannot run,
    any process left in the group counts."""
    listed = ps(["-A", "-o", "pgid=,stat="])
    if listed is None:
        try:
            os.killpg(group, 0)
        except OSError:
            return False
        return True
    for line in listed.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] == str(group) and not fields[1].startswith("Z"):
            return True
    return False

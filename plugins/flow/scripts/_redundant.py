"""Whether a worktree's uncommitted changes are already in the base branch's history.

  _redundant.py <worktree> <base ref> [--discard <fingerprint>]

Prints `redundant<TAB><fingerprint><TAB><count>` when the worktree's commit is in the base and
every changed path outside .flow/ holds, in the index and on disk, a mode and content the base's
history already gave that same path, or is deleted. Discarding such changes loses nothing: each
version is one `git show <commit>:<path>` away. The fingerprint names the exact changed state, so
two runs can tell that it did not move. Otherwise prints `kept<TAB><reason>`, the first thing
found that only the worktree holds: a conflict, a submodule, a version the base never had, a git
command in progress, a file that could not be hashed, or more changed paths than one run checks.

With --discard, checks again and, when the changes are still redundant with that same fingerprint,
restores only the checked paths to HEAD and removes only the checked untracked files, then prints
`discarded<TAB><count>`. Nothing under .flow/ is touched. Otherwise prints why it did not."""
import hashlib, os, stat, subprocess, sys

MAX_PATHS = 200
ABSENT = "000000"


def shown(path):
    """A path as one line of a health message: control characters escaped."""
    return "".join(c if c.isprintable() else repr(c)[1:-1] for c in path)


def git(worktree, args, stdin=None):
    p = subprocess.run(["git", "-C", worktree] + args, input=stdin, capture_output=True, timeout=120)
    return p.returncode, p.stdout.decode("utf-8", "surrogateescape")


def status(worktree):
    code, out = git(worktree, ["status", "--porcelain=v2", "-z", "--untracked-files=all",
                            "--ignore-submodules=none", "--no-renames", "--", ".", ":!.flow"])
    if code != 0:
        return None
    fields, entries = out.split("\0"), []
    i = 0
    while i < len(fields):
        line = fields[i]
        i += 1
        if not line:
            continue
        kind = line[0]
        if kind == "1":
            parts = line.split(" ", 8)
            entries.append((kind, parts[2], parts[4], parts[5], parts[7], parts[8]))
        elif kind == "2":
            parts = line.split(" ", 9)
            entries.append((kind, parts[2], parts[4], parts[5], parts[7], parts[9]))
            i += 1
        elif kind == "u":
            entries.append((kind, "", "", "", "", line.split(" ", 10)[10]))
        elif kind == "?":
            entries.append((kind, "N...", ABSENT, "", "", line[2:]))
    return entries


def disk_mode(worktree, path):
    full = os.path.join(worktree, path)
    if not os.path.lexists(full):
        return ABSENT
    st = os.lstat(full)
    if stat.S_ISLNK(st.st_mode):
        return "120000"
    return "100755" if st.st_mode & stat.S_IXUSR else "100644"


def disk_blobs(worktree, paths):
    """The blob each path holds on disk, hashed one path at a time so any file name is safe. A
    path that cannot be hashed is missing from the result, which assess treats as kept."""
    blobs = {}
    for path in paths:
        full = os.path.join(worktree, path)
        if disk_mode(worktree, path) == "120000":
            target = os.readlink(full).encode("utf-8", "surrogateescape")
            code, out = git(worktree, ["hash-object", "--stdin"], target)
        else:
            code, out = git(worktree, ["hash-object", "--", path])
        out = out.strip()
        if code == 0 and len(out) in (40, 64) and all(c in "0123456789abcdef" for c in out):
            blobs[path] = out
    return blobs


def history(worktree, base, paths):
    _, out = git(worktree, ["log", "--format=", "--raw", "-z", "--no-abbrev", "--no-renames", "--diff-merges=first-parent", base,
                            "--", *[":(literal)" + p for p in paths]])
    seen, fields, i = set(), out.split("\0"), 0
    while i < len(fields):
        head = fields[i].lstrip("\n")
        if head.startswith(":") and i + 1 < len(fields):
            parts = head[1:].split()
            seen.add((fields[i + 1], parts[1], parts[3]))
            i += 2
        else:
            i += 1
    return seen


def assess(worktree, base):
    _, lock = git(worktree, ["rev-parse", "--git-path", "index.lock"])
    if os.path.exists(os.path.join(worktree, lock.strip())):
        return "kept\ta git command is running there", []
    if git(worktree, ["merge-base", "--is-ancestor", "HEAD", base])[0] != 0:
        return "kept\tits commit is not in %s" % base, []
    entries = status(worktree)
    if entries is None:
        return "kept\tgit status failed there", []
    if len(entries) > MAX_PATHS:
        return "kept\t%d changed paths, more than one run checks (%d)" % (len(entries), MAX_PATHS), []
    for kind, sub, _, _, _, path in entries:
        if kind == "u":
            return "kept\t%s has a merge conflict" % shown(path), []
        if sub != "N...":
            return "kept\t%s is a submodule with changes" % shown(path), []
    paths = [entry[5] for entry in entries]
    on_disk = [p for p in paths if disk_mode(worktree, p) != ABSENT]
    blobs = disk_blobs(worktree, on_disk)
    for path in on_disk:
        if path not in blobs:
            return "kept\tthe disk version of %s could not be hashed" % shown(path), []
    known = history(worktree, base, paths)
    states = []
    for kind, _, index_mode, _, index_blob, path in entries:
        versions = [("index", index_mode, index_blob)] if index_mode != ABSENT else []
        if path in on_disk:
            versions.append(("disk", disk_mode(worktree, path), blobs[path]))
        for where, mode, blob in versions:
            if (path, mode, blob) not in known:
                what = "untracked file" if kind == "?" else "the %s version of" % where
                return "kept\t%s %s is not in %s" % (what, shown(path), base), []
        states.append("\0".join([path] + ["%s %s" % (where, blob) for where, _, blob in versions]))
    fingerprint = hashlib.sha1("\n".join(sorted(states)).encode("utf-8", "surrogateescape")).hexdigest()
    return "redundant\t%s\t%d" % (fingerprint, len(entries)), entries


def inside(worktree, path):
    root = os.path.realpath(worktree)
    parent = os.path.realpath(os.path.dirname(os.path.join(worktree, path)))
    return parent == root or parent.startswith(root + os.sep)


def discard(worktree, base, expected):
    found, entries = assess(worktree, base)
    if not found.startswith("redundant\t"):
        return found
    if found.split("\t")[1] != expected:
        return "kept\tthe changes moved since they were checked"
    tracked = [e[5] for e in entries if e[0] != "?"]
    untracked = [e[5] for e in entries if e[0] == "?"]
    if any(p == ".flow" or p.startswith(".flow/") or not inside(worktree, p) for p in tracked + untracked):
        return "kept\ta checked path is outside what health may discard"
    # Untracked files go first: a staged deletion whose file stays on disk is both a tracked and an
    # untracked entry, and the restore after this puts the HEAD version back in place.
    root = os.path.realpath(worktree)
    for path in untracked:
        full = os.path.join(worktree, path)
        try:
            os.unlink(full)
        except FileNotFoundError:
            pass
        except OSError:
            return "kept\tcould not remove %s" % shown(path)
        parent = os.path.dirname(full)
        while os.path.realpath(parent) != root:
            try:
                os.rmdir(parent)
            except OSError:
                break
            parent = os.path.dirname(parent)
    if tracked:
        code, _ = git(worktree, ["--literal-pathspecs", "restore", "--source=HEAD", "--staged", "--worktree",
                                 "--pathspec-from-file=-", "--pathspec-file-nul"],
                      ("\0".join(tracked) + "\0").encode("utf-8", "surrogateescape"))
        if code != 0:
            return "kept\tgit restore failed"
    return "discarded\t%d" % len(entries)


if len(sys.argv) == 5 and sys.argv[3] == "--discard":
    print(discard(sys.argv[1], sys.argv[2], sys.argv[4]))
else:
    print(assess(sys.argv[1], sys.argv[2])[0])

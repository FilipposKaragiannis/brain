"""Whether a worktree's uncommitted changes are already in the base branch's history.

  _redundant.py <worktree> <base ref>

Prints `redundant<TAB><fingerprint><TAB><count>` when the worktree's commit is in the base and
every changed path outside .flow/ holds, in the index and on disk, a mode and content the base's
history already gave that same path, or is deleted. Discarding such changes loses nothing: each
version is one `git show <commit>:<path>` away. The fingerprint names the exact changed state, so
two runs can tell that it did not move. Otherwise prints `kept<TAB><reason>`, the first thing
found that only the worktree holds: a conflict, a submodule, a version the base never had, a git
command in progress, or more changed paths than one run checks."""
import hashlib, os, stat, subprocess, sys

MAX_PATHS = 200
ABSENT = "000000"


def git(worktree, args, stdin=None):
    p = subprocess.run(["git", "-C", worktree] + args, input=stdin, capture_output=True, timeout=120)
    return p.returncode, p.stdout.decode("utf-8", "surrogateescape")


def status(worktree):
    _, out = git(worktree, ["status", "--porcelain=v2", "-z", "--untracked-files=all",
                            "--ignore-submodules=none", "--", ".", ":!.flow"])
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
    blobs = {}
    links = [p for p in paths if disk_mode(worktree, p) == "120000"]
    files = [p for p in paths if p not in links]
    if files:
        _, out = git(worktree, ["hash-object", "--stdin-paths"], ("\n".join(files) + "\n").encode())
        blobs.update(zip(files, out.split()))
    for path in links:
        target = os.readlink(os.path.join(worktree, path)).encode("utf-8", "surrogateescape")
        _, out = git(worktree, ["hash-object", "--stdin"], target)
        blobs[path] = out.strip()
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
        return "kept\ta git command is running there"
    if git(worktree, ["merge-base", "--is-ancestor", "HEAD", base])[0] != 0:
        return "kept\tits commit is not in %s" % base
    entries = status(worktree)
    if len(entries) > MAX_PATHS:
        return "kept\t%d changed paths, more than one run checks (%d)" % (len(entries), MAX_PATHS)
    for kind, sub, _, _, _, path in entries:
        if kind == "u":
            return "kept\t%s has a merge conflict" % path
        if sub != "N...":
            return "kept\t%s is a submodule with changes" % path
    paths = [entry[5] for entry in entries]
    blobs = disk_blobs(worktree, [p for p in paths if disk_mode(worktree, p) != ABSENT])
    known = history(worktree, base, paths)
    states = []
    for kind, _, index_mode, _, index_blob, path in entries:
        versions = [("index", index_mode, index_blob)] if index_mode != ABSENT else []
        if path in blobs:
            versions.append(("disk", disk_mode(worktree, path), blobs[path]))
        for where, mode, blob in versions:
            if (path, mode, blob) not in known:
                what = "untracked file" if kind == "?" else "the %s version of" % where
                return "kept\t%s %s is not in %s" % (what, path, base)
        states.append("\0".join([path] + ["%s %s" % (where, blob) for where, _, blob in versions]))
    fingerprint = hashlib.sha1("\n".join(sorted(states)).encode("utf-8", "surrogateescape")).hexdigest()
    return "redundant\t%s\t%d" % (fingerprint, len(entries))


print(assess(sys.argv[1], sys.argv[2]))

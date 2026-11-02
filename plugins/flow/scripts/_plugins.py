"""Claude's plugin registry, write side. See hooks/session-start.sh.

  _plugins.py sync <repo root>

Claude pins a plugin per project directory in <config dir>/plugins/installed_plugins.json. A
linked worktree is its own directory, so it keeps the version it first saw: a session there
loads that pin, `claude plugin update` run inside it reads the main checkout's record instead,
and the marketplace auto-update never touches it. sync lifts every project record of every
worktree of the repository (git worktree list) to the newest version any record of that plugin
has in the cache, and prints one line per lifted record. Silent and the file untouched when
nothing is behind. The config dir is CLAUDE_CONFIG_DIR, else ~/.claude. Sessions start together
(the jobs start several workers at once), so the read, the lift and the replace run under one
lock (installed_plugins.json.lock, next to the registry) and the new file is written to a
temporary name of its own before it replaces the registry.
"""
import fcntl
import json
import os
import subprocess
import sys
import tempfile

LIFTED_FIELDS = ("installPath", "version", "gitCommitSha", "lastUpdated")


def registry_path():
    config_dir = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    return os.path.join(config_dir, "plugins", "installed_plugins.json")


def worktree_paths(root):
    listing = subprocess.run(
        ["git", "-C", root, "worktree", "list", "--porcelain"],
        capture_output=True, text=True, check=False,
    ).stdout
    prefix = "worktree "
    paths = (line[len(prefix):] for line in listing.splitlines() if line.startswith(prefix))
    return {os.path.realpath(path) for path in paths}


def version_key(record):
    key = []
    for piece in str(record.get("version", "0")).split("."):
        digits = "".join(character for character in piece if character.isdigit())
        key.append(int(digits) if digits else 0)
    return tuple(key)


def newest_installed(records):
    installed = [record for record in records if os.path.isdir(record.get("installPath", ""))]
    return max(installed, key=version_key) if installed else None


def lift(record, newest):
    if version_key(record) >= version_key(newest):
        return False
    for field in LIFTED_FIELDS:
        if field in newest:
            record[field] = newest[field]
    return True


def write_registry(path, registry):
    directory = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(
        prefix="installed_plugins.", suffix=".tmp", dir=directory,
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(registry, handle, indent=2)
        os.replace(temporary, path)
    except BaseException:
        os.unlink(temporary)
        raise


def sync(root):
    path = registry_path()
    if not os.path.isfile(path):
        return []
    with open(path + ".lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return sync_locked(path, worktree_paths(root))


def sync_locked(path, repo_paths):
    with open(path, encoding="utf-8") as handle:
        registry = json.load(handle)
    lifted = []
    for plugin_id, records in registry.get("plugins", {}).items():
        newest = newest_installed(records)
        if newest is None:
            continue
        for record in records:
            if record.get("scope") != "project":
                continue
            project_path = record.get("projectPath", "")
            if os.path.realpath(project_path) not in repo_paths:
                continue
            was = record.get("version")
            if lift(record, newest):
                name = os.path.basename(project_path)
                lifted.append(f"{plugin_id} in {name}: {was} -> {record['version']}")
    if lifted:
        write_registry(path, registry)
    return lifted


def main(argv):
    if len(argv) != 3 or argv[1] != "sync":
        print(__doc__.strip(), file=sys.stderr)
        return 2
    for line in sync(argv[2]):
        print(f"flow: plugin pin lifted: {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

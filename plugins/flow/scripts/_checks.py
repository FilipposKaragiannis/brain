"""The build and test commands verify runs, and the key of a command's inputs. See scripts/verify.sh.

  _checks.py plan <.standards/config.json>
      Prints {"build": [check], "test": [check]}, each check {"name", "command", "paths"}.
      `build` and `test` are a command (a string, as before) or a map {command, paths}; `test`
      is also a list of {name, command, paths}, one test command each. A check with no paths
      always runs. A missing file or an empty value plans nothing. A malformed entry is named on
      stderr, exit 2.
  _checks.py key <command>
      Prints the key of the command's inputs at HEAD: the command and the git blob of every file
      under the globs read from stdin, one per line (every file when there are none). Prints
      nothing when a file under them has an uncommitted change, or when there is no commit, so
      the check runs and its pass is not kept.

Globs match as lib/flow.sh glob_match does: * and ** both cross directories.
"""
import fnmatch
import hashlib
import json
import subprocess
import sys

BUILD_NAME = "build"
TEST_NAME = "tests"
FLOW_FOLDER = ".flow/"
RENAME_STATES = ("R", "C")
STATUS_PATH_OFFSET = 3


class Malformed(Exception):
    pass


def shell_pattern(glob):
    return glob.replace("**/", "*").replace("**", "*")


def under(path, globs):
    return not globs or any(fnmatch.fnmatchcase(path, shell_pattern(glob)) for glob in globs)


def check_of(key, entry, name):
    if not isinstance(entry, dict):
        raise Malformed("%s: each entry is a map with command and paths, not %s" % (key, json.dumps(entry)))
    command = entry.get("command")
    if not isinstance(command, str) or not command.strip():
        raise Malformed("%s: %s has no command" % (key, name))
    paths = entry.get("paths", [])
    if not isinstance(paths, list) or not all(isinstance(glob, str) and glob for glob in paths):
        raise Malformed("%s: the paths of %s are a list of globs" % (key, name))
    return {"name": name, "command": command, "paths": paths}


def named_checks(key, entries):
    checks = []
    for entry in entries:
        entry_name = entry.get("name") if isinstance(entry, dict) else None
        if not isinstance(entry_name, str) or not entry_name.strip():
            raise Malformed("%s: each test command in the list has a name, and %s has none" % (key, json.dumps(entry)))
        checks.append(check_of(key, entry, "%s %s" % (TEST_NAME, entry_name.strip())))
    names = [check["name"] for check in checks]
    repeated = sorted({name for name in names if names.count(name) > 1})
    if repeated:
        raise Malformed("%s: the name %s is used more than once" % (key, repeated[0][len(TEST_NAME) + 1:]))
    return checks


def checks_of(key, value, name):
    if value is None or value == "" or value == []:
        return []
    if isinstance(value, str):
        return [{"name": name, "command": value, "paths": []}]
    if isinstance(value, dict):
        return [check_of(key, value, name)]
    if isinstance(value, list) and key == "test":
        return named_checks(key, value)
    raise Malformed("%s is a command, a map with command and paths%s" % (key, ", or a list of them" if key == "test" else ""))


def plan(config_path):
    try:
        with open(config_path, encoding="utf-8") as config_file:
            config = json.load(config_file)
    except FileNotFoundError:
        config = {}
    except ValueError as error:
        raise Malformed("the file is not JSON: %s" % error)
    if not isinstance(config, dict):
        raise Malformed("the file is not a JSON object")
    return {"build": checks_of("build", config.get("build"), BUILD_NAME),
            "test": checks_of("test", config.get("test"), TEST_NAME)}


def git(*arguments):
    return subprocess.run(("git",) + arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True).stdout


def uncommitted(globs):
    fields = git("status", "--porcelain", "-z", "--untracked-files=all").split(b"\0")
    position = 0
    while position < len(fields):
        entry = fields[position].decode("utf-8", errors="replace")
        position += 1
        if len(entry) <= STATUS_PATH_OFFSET:
            continue
        changed = [entry[STATUS_PATH_OFFSET:]]
        if entry[0] in RENAME_STATES and position < len(fields):
            changed.append(fields[position].decode("utf-8", errors="replace"))
            position += 1
        if any(not path.startswith(FLOW_FOLDER) and under(path, globs) for path in changed):
            return True
    return False


def input_key(command, globs):
    try:
        if uncommitted(globs):
            return ""
        tree = git("ls-tree", "-r", "-z", "HEAD").split(b"\0")
    except (subprocess.CalledProcessError, OSError):
        return ""
    digest = hashlib.sha256(command.encode("utf-8") + b"\0")
    for entry in sorted(tree):
        blob, _, path = entry.partition(b"\t")
        if path and under(path.decode("utf-8", errors="replace"), globs):
            digest.update(blob + b"\t" + path + b"\0")
    return digest.hexdigest()


def main(argv):
    if len(argv) == 2 and argv[0] == "plan":
        try:
            print(json.dumps(plan(argv[1])))
        except Malformed as problem:
            print(".standards/config.json: %s" % problem, file=sys.stderr)
            return 2
        return 0
    if len(argv) == 2 and argv[0] == "key":
        globs = [line.strip() for line in sys.stdin if line.strip()]
        print(input_key(argv[1], globs), end="")
        return 0
    print("usage: _checks.py plan <config.json> | key <command> (globs on stdin)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

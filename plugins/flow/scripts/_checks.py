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

  _checks.py existing <prefix> <extensions>
      Reads names, each followed by U+001F, from stdin and prints those that start with the prefix,
      end in one of the extensions (blank separated; none keeps no name) and are files now, in the
      same form. A name that is a deleted file is left out.

Globs match as lib/flow.sh glob_match does: * and ** both cross directories.
"""
import fnmatch
import hashlib
import json
import os
import subprocess
import sys
from types import MappingProxyType

BUILD_NAME = "build"
TEST_NAME = "tests"
FLOW_FOLDER = ".flow/"
RENAME_STATES = ("R", "C")
STATUS_PATH_OFFSET = 3
MALFORMED_EXIT = 2
NAME_SEPARATOR = b"\x1f"


def shell_pattern(glob):
    return glob.replace("**/", "*").replace("**", "*")


def under(path, globs):
    return not globs or any(fnmatch.fnmatchcase(path, shell_pattern(glob)) for glob in globs)


def entry_problem(key, entry, name):
    if not isinstance(entry, dict):
        return "%s: each entry is a map with command and paths, not %s" % (key, json.dumps(entry))
    command = entry.get("command")
    if not isinstance(command, str) or not command.strip():
        return "%s: %s has no command" % (key, name)
    paths = entry.get("paths", [])
    if not isinstance(paths, list) or not all(isinstance(glob, str) and glob for glob in paths):
        return "%s: the paths of %s are a list of globs" % (key, name)
    return ""


def test_name(entry):
    entry_name = entry.get("name") if isinstance(entry, dict) else None
    if not isinstance(entry_name, str) or not entry_name.strip():
        return ""
    return "%s %s" % (TEST_NAME, entry_name.strip())


def list_problem(key, entries):
    names = [test_name(entry) for entry in entries]
    for entry, name in zip(entries, names):
        if not name:
            return "%s: each test command in the list has a name, and %s has none" % (key, json.dumps(entry))
        problem = entry_problem(key, entry, name)
        if problem:
            return problem
    repeated = sorted({name for name in names if names.count(name) > 1})
    if repeated:
        return "%s: the name %s is used more than once" % (key, repeated[0][len(TEST_NAME) + 1:])
    return ""


def value_problem(key, value, name):
    if value is None or isinstance(value, str) or value == []:
        return ""
    if isinstance(value, dict):
        return entry_problem(key, value, name)
    if isinstance(value, list) and key == "test":
        return list_problem(key, value)
    return "%s is a command, a map with command and paths%s" % (key, ", or a list of them" if key == "test" else "")


def config_problem(config):
    if not isinstance(config, dict):
        return "the file is not a JSON object"
    return value_problem("build", config.get("build"), BUILD_NAME) or value_problem("test", config.get("test"), TEST_NAME)


def check_of(entry, name):
    return {"name": name, "command": entry["command"], "paths": entry.get("paths", [])}


def checks_of(value, name):
    if value is None or value == "" or value == []:
        return []
    if isinstance(value, str):
        return [{"name": name, "command": value, "paths": []}]
    if isinstance(value, dict):
        return [check_of(value, name)]
    return [check_of(entry, test_name(entry)) for entry in value]


def config_text(config_path):
    try:
        with open(config_path, encoding="utf-8") as config_file:
            return config_file.read()
    except FileNotFoundError:
        return "{}"


def print_plan(config_path):
    try:
        config = json.loads(config_text(config_path))
    except ValueError as error:
        return said_malformed("the file is not JSON: %s" % error)
    problem = config_problem(config)
    if problem:
        return said_malformed(problem)
    print(json.dumps({"build": checks_of(config.get("build"), BUILD_NAME),
                      "test": checks_of(config.get("test"), TEST_NAME)}))
    return 0


def said_malformed(problem):
    print(".standards/config.json: %s" % problem, file=sys.stderr)
    return MALFORMED_EXIT


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


def is_existing_file_under(name, wanted_prefix, wanted_endings):
    return name.startswith(wanted_prefix) and name.endswith(wanted_endings) and os.path.isfile(name)


def print_existing(prefix, extensions):
    wanted_prefix = os.fsencode(prefix)
    wanted_endings = tuple(os.fsencode(extension) for extension in extensions.split())
    names = sys.stdin.buffer.read().split(NAME_SEPARATOR)
    kept = [name for name in names if is_existing_file_under(name, wanted_prefix, wanted_endings)]
    sys.stdout.buffer.write(b"".join(name + NAME_SEPARATOR for name in kept))
    return 0


def print_key(command):
    globs = [line.strip() for line in sys.stdin if line.strip()]
    print(input_key(command, globs), end="")
    return 0


SUBCOMMANDS = MappingProxyType(
    {
        ("plan", 1): print_plan,
        ("key", 1): print_key,
        ("existing", 2): print_existing,
    }
)


def main(argv):
    subcommand = SUBCOMMANDS.get((argv[0], len(argv) - 1)) if argv else None
    if subcommand is None:
        print("usage: _checks.py plan <config.json> | key <command> (globs on stdin) | existing <prefix> <extensions> (names on stdin)", file=sys.stderr)
        return 2
    return subcommand(*argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

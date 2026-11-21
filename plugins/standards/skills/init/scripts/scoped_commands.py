"""The build and test settings of .standards/config.json, in each form they take. See init.sh.

`build` and `test` are a command (a string) or a map {command, paths}; `test` is also a list of
{name, command, paths}, one test command each. The flow verifier runs a command with paths only
when a changed file matches a glob. The flow plugin reads the same forms in its own
scripts/_checks.py: plugins install apart, so the two cannot share this file.

  scoped_commands.py commands <config.json> <build|test>
      The commands of the setting, joined by " ; ", for the testing guide. Nothing when it is
      empty or malformed.
  scoped_commands.py gaps <config.json>
      One line for each malformed entry of build and test, naming it. Nothing for a setting that
      is empty: init reports that itself.
"""
import json
import sys

SETTINGS = ("build", "test")
COMMAND_SEPARATOR = " ; "


def entry_problem(entry, where):
    if not isinstance(entry, dict):
        return "%s is a map with command and paths, not %s" % (where, json.dumps(entry))
    command = entry.get("command")
    if not isinstance(command, str) or not command.strip():
        return "%s has no command" % where
    paths = entry.get("paths", [])
    if not isinstance(paths, list) or not all(isinstance(glob, str) and glob for glob in paths):
        return "the paths of %s are a list of globs" % where
    return ""


def list_problems(entries):
    problems = []
    names = []
    for position, entry in enumerate(entries):
        name = entry.get("name") if isinstance(entry, dict) else None
        where = "test[%d]" % position
        if not isinstance(name, str) or not name.strip():
            problems.append("%s has no name" % where)
        else:
            where = "%s (%s)" % (where, name)
            names.append(name)
        problem = entry_problem(entry, where)
        if problem:
            problems.append(problem)
    problems += ["test: the name %s is used more than once" % name for name in sorted(set(names)) if names.count(name) > 1]
    return problems


def problems_of(setting, value):
    if value is None or value == "" or value == [] or isinstance(value, str):
        return []
    if isinstance(value, dict):
        problem = entry_problem(value, setting)
        return [problem] if problem else []
    if isinstance(value, list) and setting == "test":
        return list_problems(value)
    return ["%s is a command, a map with command and paths%s" % (setting, ", or a list of them" if setting == "test" else "")]


def commands_of(value):
    if isinstance(value, str):
        return [value] if value else []
    if isinstance(value, dict):
        return [value["command"]]
    return [entry["command"] for entry in value or []]


def load(path):
    try:
        with open(path, encoding="utf-8") as config_file:
            config = json.load(config_file)
    except (OSError, ValueError):
        return {}
    return config if isinstance(config, dict) else {}


def main(argv):
    if len(argv) == 3 and argv[0] == "commands" and argv[2] in SETTINGS:
        value = load(argv[1]).get(argv[2])
        if not problems_of(argv[2], value):
            print(COMMAND_SEPARATOR.join(commands_of(value)), end="")
        return 0
    if len(argv) == 2 and argv[0] == "gaps":
        config = load(argv[1])
        for setting in SETTINGS:
            for problem in problems_of(setting, config.get(setting)):
                print(".standards/config.json: %s" % problem)
        return 0
    print("usage: scoped_commands.py commands <config.json> <build|test> | gaps <config.json>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

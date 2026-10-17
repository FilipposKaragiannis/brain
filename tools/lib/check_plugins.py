"""Check that what a plugin runs or installs from its own folder is there.

  check_plugins.py [root]   (default: the current directory)

Two checks, each finding printed as a "lint:" line, exit 1 on any:
  hooks   every command in plugins/*/hooks/hooks.json names a script inside the plugin that
          exists and is executable (the host runs it directly)
  paths   every literal path under the plugin root that a shipped file names exists: through
          ${CLAUDE_PLUGIN_ROOT} or $FLOW_PLUGIN anywhere, and through $plugin in the installers
          (skills/init/scripts/*.sh, where $plugin is the plugin root). A path with a glob, a
          printf slot or a placeholder is skipped.
tools/tests/run.sh runs it on a broken fixture to prove it fails.
"""
import glob
import json
import os
import re
import shlex
import sys

ROOT_VARS = r"\$\{?(?:CLAUDE_PLUGIN_ROOT|FLOW_PLUGIN)\}?"
INSTALLER_VARS = r"\$\{?(?:CLAUDE_PLUGIN_ROOT|FLOW_PLUGIN|plugin)\}?"
PATH_TAIL = r"\"?(/[A-Za-z0-9_.\-/]*)"
OPEN_ENDED = "*?[%<{$|"
SKIPPED_DIRS = ("evals", "tests")


def hook_findings(plugin_dir):
    path = os.path.join(plugin_dir, "hooks", "hooks.json")
    if not os.path.exists(path):
        return []
    found = []
    for event, groups in json.load(open(path)).get("hooks", {}).items():
        for group in groups:
            for hook in group.get("hooks", []):
                if hook.get("type") != "command":
                    continue
                command = hook.get("command", "").replace("${CLAUDE_PLUGIN_ROOT}", plugin_dir)
                words = shlex.split(command)
                script = words[0] if words else ""
                where = "%s %s: %s" % (path, event, hook.get("command", ""))
                if not script.startswith(plugin_dir + "/"):
                    found.append("hook command does not name a script in the plugin: %s" % where)
                elif not os.path.isfile(script):
                    found.append("hook script missing: %s" % where)
                elif not os.access(script, os.X_OK):
                    found.append("hook script not executable: %s" % where)
    return found


def shipped_files(plugin_dir):
    for path in glob.glob(os.path.join(plugin_dir, "**", "*"), recursive=True):
        relative = os.path.relpath(path, plugin_dir).split(os.sep)
        if relative[0] in SKIPPED_DIRS or not os.path.isfile(path):
            continue
        yield path


def path_findings(plugin_dir):
    found = []
    installers = set(glob.glob(os.path.join(plugin_dir, "skills", "init", "scripts", "*.sh")))
    for path in sorted(shipped_files(plugin_dir)):
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        variables = INSTALLER_VARS if path in installers else ROOT_VARS
        targets = set()
        for match in re.finditer(variables + PATH_TAIL, text):
            following = text[match.end():match.end() + 1]
            target = match.group(1).rstrip("/.")
            if target and (not following or following not in OPEN_ENDED):
                targets.add(target)
        for target in sorted(targets):
            if not os.path.exists(plugin_dir + target):
                found.append("%s names a missing plugin path: %s" % (path, target.lstrip("/")))
    return found


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    findings = []
    for plugin_dir in sorted(glob.glob(os.path.join(root, "plugins", "*", ""))):
        plugin_dir = plugin_dir.rstrip("/")
        findings += hook_findings(plugin_dir) + path_findings(plugin_dir)
    for finding in findings:
        print("lint: " + finding)
    sys.exit(1 if findings else 0)


main()

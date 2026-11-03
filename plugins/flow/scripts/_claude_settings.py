"""The Claude worktree hook entries flow:init keeps in this user's .claude/settings.local.json.

  _claude_settings.py merge <settings file> <out file> <create command> <remove command>
      Writes to the out file the settings with flow's WorktreeCreate and WorktreeRemove commands in
      place of any flow hook the file had (a hook whose command runs .flow/hooks/worktree-*),
      every other key, group and hook kept, a flow hook's own group settings and sibling hooks
      too. A missing or empty file counts as {}. Exit 0 when the file already holds exactly those
      commands (nothing written), 1 when the out file was written, 2 when the settings file is not
      a JSON object (the reason on stderr).
  _claude_settings.py committed <settings file>
      Prints the hook groups with a flow hook that a shared settings file still carries, as
      indented JSON shaped like the settings' own hooks key, or nothing when it has none or cannot
      be read.
"""
import copy, json, sys

FLOW_HOOK_MARK = ".flow/hooks/worktree-"
EVENTS = ("WorktreeCreate", "WorktreeRemove")


class SettingsProblem(Exception):
    pass


def load(path):
    try:
        with open(path, encoding="utf-8") as settings_file:
            text = settings_file.read()
    except FileNotFoundError:
        return {}
    if not text.strip():
        return {}
    try:
        settings = json.loads(text)
    except json.JSONDecodeError as error:
        raise SettingsProblem(f"{path} is not valid JSON (line {error.lineno} column {error.colno}: {error.msg})")
    if not isinstance(settings, dict):
        raise SettingsProblem(f"{path} holds a JSON {type(settings).__name__}, not an object")
    return settings


def is_flow_hook(hook):
    return isinstance(hook, dict) and FLOW_HOOK_MARK in str(hook.get("command", ""))


def group_hooks(group):
    hooks = group.get("hooks") if isinstance(group, dict) else None
    return hooks if isinstance(hooks, list) else []


def has_flow_hook(group):
    return any(is_flow_hook(hook) for hook in group_hooks(group))


def flow_group(command):
    return {"hooks": [{"type": "command", "command": command}]}


def event_groups(settings, path, event):
    hooks = settings.get("hooks", {})
    if not isinstance(hooks, dict):
        raise SettingsProblem(f"{path}: the hooks key holds a {type(hooks).__name__}, not an object")
    groups = hooks.get(event, [])
    if not isinstance(groups, list):
        raise SettingsProblem(f"{path}: hooks.{event} holds a {type(groups).__name__}, not a list")
    return groups


def replace_flow_hooks(hooks, command):
    """The hooks with the first flow hook running the command (its other keys kept) and every later
    flow hook dropped; with no command, every flow hook dropped. Other hooks stay in their place."""
    kept = []
    for hook in hooks:
        if not is_flow_hook(hook):
            kept.append(hook)
        elif command is not None:
            kept.append({**hook, "type": "command", "command": command}); command = None
    return kept


def with_flow_hook(groups, command):
    """The groups with flow's command on the first flow hook (a new group last when there is none)
    and no other flow hook. A group keeps its own settings and its other hooks, and goes only when
    it held nothing but flow hooks that were dropped."""
    result, placed = [], False
    for group in groups:
        if not has_flow_hook(group):
            result.append(group); continue
        kept = replace_flow_hooks(group_hooks(group), None if placed else command)
        placed = True
        if kept:
            result.append({**group, "hooks": kept})
    return result if placed else result + [flow_group(command)]


def merge(path, out_path, create_command, remove_command):
    settings = load(path)
    merged = copy.deepcopy(settings)
    for event, command in zip(EVENTS, (create_command, remove_command)):
        groups = event_groups(settings, path, event)
        merged.setdefault("hooks", {})[event] = with_flow_hook(groups, command)
    if merged == settings:
        return 0
    with open(out_path, "w", encoding="utf-8") as out_file:
        out_file.write(json.dumps(merged, indent=2, ensure_ascii=False) + "\n")
    return 1


def committed(path):
    try:
        settings = load(path)
        found = {event: [group for group in event_groups(settings, path, event) if has_flow_hook(group)] for event in EVENTS}
    except SettingsProblem:
        return 0
    found = {event: groups for event, groups in found.items() if groups}
    if found:
        print(json.dumps({"hooks": found}, indent=2, ensure_ascii=False))
    return 0


def main(arguments):
    if len(arguments) == 5 and arguments[0] == "merge":
        try:
            return merge(*arguments[1:])
        except SettingsProblem as problem:
            print(problem, file=sys.stderr)
            return 2
    if len(arguments) == 2 and arguments[0] == "committed":
        return committed(arguments[1])
    print("usage: _claude_settings.py merge <settings> <out> <create command> <remove command> | committed <settings>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

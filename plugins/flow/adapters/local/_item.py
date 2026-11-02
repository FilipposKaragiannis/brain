"""Frontmatter item files for the local adapter. Used by the local/*.sh entry points.

An item is <flow home>/items/<kind>/<n>.md: YAML frontmatter (flat keys, inline lists) and a
Markdown body. Comments are appended under "## Comments". Needs python3 >= 3.9 only.

Usage (always from the shell scripts):
  _item.py list <home> [--all] [--kind KIND] [--pick NAME]
  _item.py read <home> <id>
  _item.py write-state <home> <id> key=value...
  _item.py comment <home> <id> <text>
  _item.py close <home> <id> [<text>]
  _item.py create <home> <kind> <title> [--size S] [--blocked-by a,b] [--body TEXT] [--labels a,b] [--parent ID] [--area NAME] [--priority NAME] [--type NAME]

A list with --pick keeps the items its filter matches: the item file's assignee (`me` is the git
user's email or name), status, labels and kind, each compared without case.

An item's open_children counts the open items whose parent it is. Its rank places its priority in
READY_PRIORITY_ORDER and needs lists the READY_NEEDS fields an open, unstarted item lacks (the
GitHub adapter's issue_to_item applies the same rule; change both).
"""
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

STATE_KEYS = ["step", "profile", "size", "worktree", "attempts", "gate", "last_event", "pr", "pr_host", "touches",
              "answered", "asked", "answer", "answered_at", "gate_from"]
LIST_KEYS = {"blocked_by", "labels", "touches"}
INT_KEYS = {"attempts"}
# The rank of an item with no priority: after every ranked one.
NO_RANK = 999


def usage(message):
    sys.stderr.write("flow: %s\n" % message)
    sys.exit(2)


def now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_list(text):
    text = text.strip()
    if text.startswith("["):
        text = text[1:-1] if text.endswith("]") else text[1:]
    return [unquote(p) for p in (x.strip() for x in text.split(",")) if p]


def unquote(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] == '"':
        try:
            return json.loads(s)
        except ValueError:
            return s[1:-1]
    if len(s) >= 2 and s[0] == s[-1] == "'":
        return s[1:-1]
    return s


def quote(s):
    s = str(s)
    if s == "" or re.search(r"[:#\[\]{},\"'\n]|^\s|\s$", s) or s.lower() in ("true", "false", "null", "none"):
        return json.dumps(s, ensure_ascii=False)
    return s


def dump_list(items):
    return "[" + ", ".join(quote(i) for i in items) + "]"


def parse(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    meta, body = {}, text
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            head, body = text[4:end], text[end + 5:]
            for line in head.splitlines():
                if not line.strip() or line.lstrip().startswith("#") or ":" not in line:
                    continue
                key, value = line.split(":", 1)
                key = key.strip().replace("-", "_")
                value = value.strip()
                if key in LIST_KEYS:
                    meta[key] = parse_list(value)
                elif key in INT_KEYS:
                    meta[key] = int(value) if value.isdigit() else 0
                else:
                    meta[key] = unquote(value)
    return meta, body


def dump(path, meta, body):
    lines = ["---"]
    for key, value in meta.items():
        if key in LIST_KEYS:
            lines.append("%s: %s" % (key, dump_list(value or [])))
        else:
            lines.append("%s: %s" % (key, quote(value if value is not None else "")))
    lines.append("---")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n" + body.lstrip("\n"))


def item_path(home, item_id):
    if not item_id.startswith("local:") or "/" not in item_id:
        usage("not a local item id: %s" % item_id)
    kind, n = item_id[len("local:"):].split("/", 1)
    return os.path.join(home, "items", kind, n + ".md")


def open_children(home):
    counts = {}
    for path in glob.glob(os.path.join(home, "items", "*", "*.md")):
        meta, _ = parse(path)
        if meta.get("parent") and meta.get("status", "open") == "open":
            counts[meta["parent"]] = counts.get(meta["parent"], 0) + 1
    return counts


def ready_list(name):
    return [value for value in os.environ.get(name, "").split(",") if value]


def rank(priority):
    order = ready_list("READY_PRIORITY_ORDER")
    if not priority:
        return NO_RANK
    return order.index(priority) if priority in order else len(order)


def needs(meta):
    if meta.get("status", "open") != "open" or meta.get("step"):
        return []
    return [field for field in ready_list("READY_NEEDS")
            if not meta.get(field) and not (field == "size" and meta.get("kind") == "epic")]


def to_json(path, meta, body, children=None):
    state = {k: meta.get(k, [] if k == "touches" else (0 if k == "attempts" else "")) for k in STATE_KEYS}
    if not state["gate"]:
        state["gate"] = "none"
    return {
        "id": meta.get("id", ""),
        "kind": meta.get("kind", "task"),
        "title": meta.get("title", ""),
        "size": meta.get("size", ""),
        "status": meta.get("status", "open"),
        "labels": meta.get("labels", []),
        "blocked_by": meta.get("blocked_by", []),
        "parent": meta.get("parent", ""),
        "priority": meta.get("priority", ""),
        "area": meta.get("area", ""),
        "rank": rank(meta.get("priority", "")),
        "needs": needs(meta),
        "open_children": (children or {}).get(meta.get("id", ""), 0),
        "state": state,
        "url": path,
        "body": body,
    }


def git_identity():
    """The names `me` stands for in a filter: the git user's email and name, lower case."""
    names = set()
    for key in ("user.email", "user.name"):
        try:
            out = subprocess.run(["git", "config", key], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            continue
        if out.stdout.strip():
            names.add(out.stdout.strip().lower())
    return names


def pick_rules():
    """The filter of `list --pick` (pick_filter in lib/flow.sh): each field it sets, as a set of
    lower-case values an item must match one of."""
    rules = {}
    for field in ("status", "labels", "kinds"):
        values = {v.strip().lower() for v in ready_list("FLOW_PICK_" + field.upper())}
        if values:
            rules[field] = values
    assignee = os.environ.get("FLOW_PICK_ASSIGNEE", "").strip()
    if assignee:
        rules["assignee"] = git_identity() if assignee == "me" else {assignee.lower()}
    return rules


def picked(meta, rules):
    values = {
        "assignee": {str(meta.get("assignee", "")).lower()},
        "status": {meta.get("status", "open").lower()},
        "labels": {label.lower() for label in meta.get("labels", [])},
        "kinds": {meta.get("kind", "task").lower()},
    }
    return all(values[field] & wanted for field, wanted in rules.items())


def cmd_list(home, args):
    want_all, kind, i = False, None, 0
    while i < len(args):
        if args[i] == "--all":
            want_all = True; i += 1
        elif args[i] == "--kind" and i + 1 < len(args):
            kind = args[i + 1]; i += 2
        elif args[i] == "--pick" and i + 1 < len(args):
            i += 2  # list.sh has exported the filter as FLOW_PICK_* (pick_rules)
        else:
            usage("unknown option %s" % args[i])
    items, children, rules = [], open_children(home), pick_rules()
    for path in sorted(glob.glob(os.path.join(home, "items", "*", "*.md")), key=natural_key):
        meta, body = parse(path)
        if kind and meta.get("kind") != kind:
            continue
        if not want_all and meta.get("status", "open") != "open":
            continue
        if not picked(meta, rules):
            continue
        items.append(to_json(path, meta, body, children))
    print(json.dumps(items))


def natural_key(path):
    kind = os.path.basename(os.path.dirname(path))
    n = os.path.splitext(os.path.basename(path))[0]
    return (kind, int(n) if n.isdigit() else 10**9, n)


def cmd_read(home, args):
    path = item_path(home, args[0])
    if not os.path.exists(path):
        raise SystemExit("flow: no such item %s" % args[0])
    meta, body = parse(path)
    print(json.dumps(to_json(path, meta, body, open_children(home))))


def cmd_write_state(home, args):
    path = item_path(home, args[0])
    meta, body = parse(path)
    for kv in args[1:]:
        if "=" not in kv:
            usage("expected key=value, got %s" % kv)
        key, value = kv.split("=", 1)
        key = key.replace("-", "_")
        if key not in STATE_KEYS:
            usage("unknown state key %s" % key)
        if key in LIST_KEYS:
            meta[key] = [v for v in value.split(",") if v.strip()]
        elif key in INT_KEYS:
            meta[key] = int(value or 0)
        else:
            meta[key] = value
    dump(path, meta, body)


def cmd_comment(home, args):
    path = item_path(home, args[0])
    meta, body = parse(path)
    body = append_comment(body, args[1])
    dump(path, meta, body)


def append_comment(body, text):
    if "\n## Comments" not in body and not body.startswith("## Comments"):
        body = body.rstrip("\n") + "\n\n## Comments\n"
    return body.rstrip("\n") + "\n- %s: %s\n" % (now(), text.strip().replace("\n", "\n  "))


def cmd_close(home, args):
    path = item_path(home, args[0])
    meta, body = parse(path)
    meta["status"] = "closed"
    meta["closed"] = now()
    if len(args) > 1 and args[1]:
        body = append_comment(body, args[1])
    dump(path, meta, body)


def cmd_create(home, args):
    kind, title, rest = args[0], args[1], args[2:]
    opt = {"size": "", "blocked_by": [], "body": "", "labels": [], "parent": "", "area": "", "priority": ""}
    i = 0
    while i < len(rest):
        if rest[i] == "--size":
            opt["size"] = rest[i + 1]; i += 2
        elif rest[i] == "--blocked-by":
            opt["blocked_by"] = [x for x in rest[i + 1].split(",") if x]; i += 2
        elif rest[i] == "--body":
            opt["body"] = rest[i + 1]; i += 2
        elif rest[i] == "--labels":
            opt["labels"] = [x for x in rest[i + 1].split(",") if x]; i += 2
        elif rest[i] == "--parent":
            opt["parent"] = rest[i + 1]; i += 2
        elif rest[i] == "--area":
            opt["area"] = rest[i + 1]; i += 2
        elif rest[i] == "--priority":
            opt["priority"] = rest[i + 1]; i += 2
        elif rest[i] == "--type":
            sys.stderr.write("flow: the local tracker has no issue types, so --type %s is left out\n" % rest[i + 1]); i += 2
        else:
            usage("unknown option %s" % rest[i])
    folder = os.path.join(home, "items", kind)
    os.makedirs(folder, exist_ok=True)
    numbers = [int(os.path.splitext(os.path.basename(p))[0]) for p in glob.glob(os.path.join(folder, "*.md"))
               if os.path.splitext(os.path.basename(p))[0].isdigit()]
    n = max(numbers, default=0) + 1
    item_id = "local:%s/%d" % (kind, n)
    meta = {"id": item_id, "kind": kind, "title": title, "size": opt["size"], "status": "open",
            "blocked_by": opt["blocked_by"], "labels": opt["labels"], "parent": opt["parent"], "step": "", "profile": "",
            "worktree": "", "attempts": 0, "gate": "none", "last_event": "", "pr": "", "touches": [],
            "created": now()}
    for key in ("area", "priority"):
        if opt[key]:
            meta[key] = opt[key]
    dump(os.path.join(folder, "%d.md" % n), meta, "# %s\n\n%s\n" % (title, opt["body"]))
    print(item_id)


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cmd, home, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    {"list": cmd_list, "read": cmd_read, "write-state": cmd_write_state, "comment": cmd_comment,
     "close": cmd_close, "create": cmd_create}[cmd](home, args)


if __name__ == "__main__":
    main()

"""Frontmatter item files for the local adapter. Used by the local/*.sh entry points.

An item is <flow home>/items/<kind>/<n>.md: YAML frontmatter (flat keys, inline lists) and a
Markdown body. Comments are appended under "## Comments". Needs python3 >= 3.9 only.

Usage (always from the shell scripts):
  _item.py list <home> [--all] [--kind KIND]
  _item.py read <home> <id>
  _item.py write-state <home> <id> key=value...
  _item.py comment <home> <id> <text>
  _item.py close <home> <id> [<text>]
  _item.py create <home> <kind> <title> [--size S] [--blocked-by a,b] [--body TEXT] [--labels a,b] [--parent ID] [--area NAME] [--priority NAME]

An item's open_children counts the open items whose parent it is.
"""
import glob
import json
import os
import re
import sys
from datetime import datetime, timezone

STATE_KEYS = ["step", "profile", "size", "worktree", "attempts", "gate", "last_event", "pr", "touches",
              "answered", "asked", "answer", "answered_at", "gate_from"]
LIST_KEYS = {"blocked_by", "labels", "touches"}
INT_KEYS = {"attempts"}


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
        raise SystemExit("flow: not a local item id: %s" % item_id)
    kind, n = item_id[len("local:"):].split("/", 1)
    return os.path.join(home, "items", kind, n + ".md")


def open_children(home):
    counts = {}
    for path in glob.glob(os.path.join(home, "items", "*", "*.md")):
        meta, _ = parse(path)
        if meta.get("parent") and meta.get("status", "open") == "open":
            counts[meta["parent"]] = counts.get(meta["parent"], 0) + 1
    return counts


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
        "open_children": (children or {}).get(meta.get("id", ""), 0),
        "state": state,
        "url": path,
        "body": body,
    }


def cmd_list(home, args):
    want_all = "--all" in args
    kind = args[args.index("--kind") + 1] if "--kind" in args else None
    items, children = [], open_children(home)
    for path in sorted(glob.glob(os.path.join(home, "items", "*", "*.md")), key=natural_key):
        meta, body = parse(path)
        if kind and meta.get("kind") != kind:
            continue
        if not want_all and meta.get("status", "open") != "open":
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
            raise SystemExit("flow: expected key=value, got %s" % kv)
        key, value = kv.split("=", 1)
        key = key.replace("-", "_")
        if key not in STATE_KEYS:
            raise SystemExit("flow: unknown state key %s" % key)
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
        else:
            raise SystemExit("flow: unknown option %s" % rest[i])
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

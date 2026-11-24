"""Jira Cloud items through the REST API v3, for the jira/*.sh entry points. See adapters/README.md.

  _jira.py list [--all] [--kind KIND] [--pick NAME]
  _jira.py read <id>
  _jira.py in-scope <id>
  _jira.py create <kind> <title> [--size S] [--priority NAME] [--area NAME] [--type NAME]
                  [--blocked-by id,id] [--parent id] [--body TEXT]
  _jira.py write-state <id> key=value...
  _jira.py comment <id> <text>
  _jira.py close <id> [<text>]
  _jira.py remote-link <id> <url>
  _jira.py answers
  _jira.py vocabulary

Every call goes through curl (_http.py). The settings come from _jira.sh in FLOW_JIRA_* variables,
the readiness rules from ready_rules (READY_NEEDS, READY_PRIORITY_ORDER), the token from
JIRA_API_TOKEN. Items are issues of one project; ids are jira:<KEY>-<n>. The flow
state is mirrored as labels the way the GitHub adapter does it (step:*, gate:*, wt:*, flow:*, and
size:* unless jira.fields.size names a field) and kept whole in the issue property flow-state.
A blocker in another tracker has no Jira link, so it sits in the description as a line
"Blocked by: <id>, <id>", as does a Jira blocker whose link Jira refused.
answers prints one JSON line {"id", "text"} per gated item the owner answered with an /answer
comment; answers.sh clears the gates. jira.scope (scope_filter in lib/flow.sh, FLOW_SCOPE_*) is
ANDed into every search: list, its children counts, read's children count and answers; in-scope
exits 0 when the issue is inside it, 1 when not. vocabulary prints the project's issue types and
the options of the jira.fields.area field.
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _fields import custom_fields, field_input, field_text, from_document, setting, to_document  # noqa: E402
from _http import call, expect, fail  # noqa: E402

PREFIX = "jira:"
KEY = re.compile(r"^[A-Z][A-Z0-9_]*-[0-9]+$")
STATE_PROPERTY = "flow-state"
STATE_KEYS = ["step", "profile", "size", "worktree", "attempts", "gate", "last_event", "pr", "pr_host", "touches",
              "changes", "held_by", "held_reason", "answered", "asked", "answer", "answered_at", "answer_pending", "gate_from",
              "base", "branch"]
LABEL_PREFIXES = {"step": "step:", "gate": "gate:", "worktree": "wt:", "profile": "flow:", "size": "size:"}
FIELDS = ["summary", "description", "status", "issuetype", "priority", "labels", "parent", "issuelinks", "assignee"]
STATUS_CATEGORY_KEYS = {"new": "todo", "indeterminate": "in-progress", "done": "done"}
FOREIGN_BLOCKERS = re.compile(r"(?m)^Blocked by: (.+)$")
NO_RANK = 999
PAGE_SIZE = 100
SEARCH = "/rest/api/3/search/jql"
GATE_COMMENT = "**Gate: "
ANSWER_WORD = "/answer"
# Gates an /answer comment clears; the merge gate clears when the PR is merged.
UNANSWERABLE_GATES = ("none", "merge")
PICK = "FLOW_PICK_"
SCOPE = "FLOW_SCOPE_"


def key_of(item_id):
    key = item_id[len(PREFIX):] if item_id.startswith(PREFIX) else ""
    if not KEY.match(key):
        fail("not a Jira item id: %s" % item_id, 2)
    return key


def type_names():
    return {kind: setting("TYPE_" + kind.upper(), kind.capitalize()) for kind in ("epic", "task", "bug")}


# --- reading


def readiness(item, is_open):
    order = [p for p in os.environ.get("READY_PRIORITY_ORDER", "").split(",") if p]
    priority = item["priority"]
    item["rank"] = NO_RANK if not priority else order.index(priority) if priority in order else len(order)
    item["needs"] = []
    if not is_open or item["state"]["step"]:
        return
    for need in [n for n in os.environ.get("READY_NEEDS", "").split(",") if n]:
        if need == "priority" and not priority:
            item["needs"].append(need)
        if need == "size" and not item["size"] and item["kind"] != "epic":
            item["needs"].append(need)


def flow_state(issue, labels, fields):
    state = {"step": "", "profile": "", "size": "", "worktree": "", "attempts": 0, "gate": "none",
             "last_event": "", "pr": "", "touches": [], "changes": [], "held_by": "", "held_reason": ""}
    state.update((issue.get("properties") or {}).get(STATE_PROPERTY) or {})
    for key, prefix in LABEL_PREFIXES.items():
        if key == "size" and "size" in fields:
            continue
        state[key] = next((l[len(prefix):] for l in labels if l.startswith(prefix)), state.get(key, ""))
    state["gate"] = state["gate"] or "none"
    return state


def status_names(name: str) -> set:
    return {status.strip().lower() for status in setting(name).split(",") if status.strip()}


def category_of(status: dict) -> str:
    name = status.get("name", "").lower()
    if name in status_names("STATUS_REVIEW"):
        return "review"
    if name in status_names("STATUS_BLOCKED"):
        return "blocked"
    return STATUS_CATEGORY_KEYS.get((status.get("statusCategory") or {}).get("key", ""), "unknown")


def assignees_of(issue_fields: dict) -> list:
    """A user's privacy setting can hide the email, so the account id stands in for it."""
    person = issue_fields.get("assignee") or {}
    identity = person.get("emailAddress") or person.get("accountId") or ""
    return [identity] if identity else []


def kind_of(issue_fields):
    """The flow kind of an issue's fields, as jira.types maps the issue types; any other type is a task."""
    type_name = (issue_fields.get("issuetype") or {}).get("name", "")
    return {name: kind for kind, name in type_names().items()}.get(type_name, "task")


def to_item(issue, fields, open_children):
    data = issue["fields"]
    labels = data.get("labels") or []
    state = flow_state(issue, labels, fields)
    if "size" in fields:
        state["size"] = field_text(data.get(fields["size"]["id"])) or state.get("size", "")
    type_name = (data.get("issuetype") or {}).get("name", "")
    kind = kind_of(data)
    is_open = ((data.get("status") or {}).get("statusCategory") or {}).get("key") != "done"
    body = from_document(data.get("description"))
    links = [l for l in data.get("issuelinks") or [] if (l.get("type") or {}).get("name") == "Blocks" and l.get("inwardIssue")]
    foreign = [b.strip() for line in FOREIGN_BLOCKERS.findall(body) for b in line.split(",") if b.strip()]
    linked_ids = [PREFIX + l["inwardIssue"]["key"] for l in links]
    item = {
        "id": PREFIX + issue["key"], "kind": kind, "type": type_name, "title": data.get("summary", ""), "body": body,
        "status": "open" if is_open else "closed", "category": category_of(data.get("status") or {}),
        "assignees": assignees_of(data), "size": state["size"],
        "priority": (data.get("priority") or {}).get("name", ""),
        "area": field_text(data.get(fields["area"]["id"])) if "area" in fields else "",
        "labels": labels, "blocked_by": linked_ids + [b for b in foreign if b not in linked_ids],
        "parent": PREFIX + data["parent"]["key"] if data.get("parent") else "",
        "open_children": open_children, "url": "%s/browse/%s" % (setting("SITE").rstrip("/"), issue["key"]),
        "state": state,
    }
    if not foreign:
        item["open_blockers"] = [PREFIX + l["inwardIssue"]["key"] for l in links
                                 if ((l["inwardIssue"].get("fields") or {}).get("status") or {}).get("statusCategory", {}).get("key") != "done"]
    readiness(item, is_open)
    return item


def search(jql, fields, limit):
    issues, token = [], None
    while len(issues) < limit:
        body = {"jql": jql, "fields": fields, "properties": [STATE_PROPERTY], "maxResults": min(PAGE_SIZE, limit - len(issues))}
        if token:
            body["nextPageToken"] = token
        status, page = call("POST", SEARCH, body)
        expect(status, page, "search Jira")
        issues += page.get("issues") or []
        token = page.get("nextPageToken")
        if page.get("isLast", True) or not token:
            return issues, False
    return issues, True


def field_list(fields):
    return FIELDS + [f["id"] for f in fields.values()]


def jql_text(value):
    return '"%s"' % value.replace("\\", "\\\\").replace('"', '\\"')


def pick_values(prefix, name):
    return [v.strip() for v in os.environ.get(prefix + name, "").split(",") if v.strip()]


def pick_conditions(prefix):
    """The JQL conditions of `list --pick` (pick_filter in lib/flow.sh, prefix FLOW_PICK_) or of
    jira.scope (scope_filter, prefix FLOW_SCOPE_): its query as written, else the assignee (me is
    currentUser(), the jira.email login the token belongs to), the statuses, the labels and the
    kinds (kind_condition), so jira.limit counts only the issues the filter keeps."""
    query = os.environ.get(prefix + "QUERY", "").strip()
    if query:
        return ["(%s)" % query]
    conditions = []
    assignee = os.environ.get(prefix + "ASSIGNEE", "").strip()
    if assignee:
        conditions.append("assignee = %s" % ("currentUser()" if assignee == "me" else jql_text(assignee)))
    for field, name in (("status", "STATUS"), ("labels", "LABELS")):
        if pick_values(prefix, name):
            conditions.append("%s in (%s)" % (field, ", ".join(jql_text(v) for v in pick_values(prefix, name))))
    return conditions + kind_condition({k.lower() for k in pick_values(prefix, "KINDS")})


def kind_condition(kinds):
    """The JQL for the issue types of the kinds, as kind_of maps them back: an epic or a bug is its
    jira.types name, a task any other type. Empty for no kinds or every kind; a kind that is no
    flow kind matches no issue."""
    names = type_names()
    wanted = kinds & set(names)
    if not kinds or wanted == set(names):
        return []
    if "task" in wanted:
        return ["issuetype not in (%s)" % ", ".join(jql_text(names[k]) for k in sorted(set(names) - wanted))]
    if wanted:
        return ["issuetype in (%s)" % ", ".join(jql_text(names[k]) for k in sorted(wanted))]
    return ["issuetype is EMPTY"]


def scope_conditions():
    return pick_conditions(SCOPE)


def children_of(issues, scope, narrowed):
    """Each listed issue's open children inside the scope. A list a scope or a filter narrowed can
    leave a child out, so its children are searched for apart, every page of them: a count cut at
    jira.limit would read a parent with open children as having none, and so as ready."""
    rows = issues
    if narrowed and issues:
        conditions = ["parent in (%s)" % ", ".join(i["key"] for i in issues)] + scope + ["statusCategory != Done"]
        rows, _ = search(" AND ".join(conditions), ["parent", "status"], sys.maxsize)
    children = {}
    for issue in rows:
        parent = issue["fields"].get("parent")
        if parent and (issue["fields"].get("status") or {}).get("statusCategory", {}).get("key") != "done":
            children[parent["key"]] = children.get(parent["key"], 0) + 1
    return children


def cmd_list(args):
    want_all, kind, i = False, None, 0
    while i < len(args):
        if args[i] == "--all":
            want_all, i = True, i + 1
        elif args[i] == "--kind" and i + 1 < len(args):
            kind, i = args[i + 1], i + 2
        elif args[i] == "--pick" and i + 1 < len(args):
            i += 2  # list.sh has exported the filter as FLOW_PICK_* (pick_conditions)
        else:
            fail("unknown option %s" % args[i], 2)
    fields, limit = custom_fields(), int(setting("LIMIT", "500"))
    scope, picked = scope_conditions(), pick_conditions(PICK)
    conditions = ["project = %s" % jql_text(setting("PROJECT"))] + scope + picked + ([] if want_all else ["statusCategory != Done"])
    issues, cut = search(" AND ".join(conditions) + " ORDER BY created DESC", field_list(fields), limit)
    if cut:
        sys.stderr.write("flow: stopped at jira.limit %d issues; raise it in .flow/config.yaml\n" % limit)
        if os.environ.get("FLOW_LIST_WHOLE"):
            sys.exit(1)
    children = children_of(issues, scope, bool(scope or picked))
    items = [to_item(issue, fields, children.get(issue["key"], 0)) for issue in issues]
    kept = [i for i in items if not kind or i["kind"] == kind]
    print(json.dumps(kept))


def read_issue(key, fields):
    query = {"fields": ",".join(field_list(fields)), "properties": STATE_PROPERTY}
    status, issue = call("GET", "/rest/api/3/issue/" + key, query=query)
    if status == 404:
        fail("no such item %s%s" % (PREFIX, key))
    expect(status, issue, "read %s%s" % (PREFIX, key))
    return issue


def cmd_read(args):
    key, fields = key_of(args[0]), custom_fields()
    issue = read_issue(key, fields)
    conditions = ["parent = %s" % key] + scope_conditions() + ["statusCategory != Done"]
    children, _ = search(" AND ".join(conditions), ["summary"], int(setting("LIMIT", "500")))
    print(json.dumps(to_item(issue, fields, len(children))))


def cmd_in_scope(args):
    """Exit 0 when the issue is inside jira.scope, or no scope is set (no call); 1 when it is not."""
    key, scope = key_of(args[0]), scope_conditions()
    if not scope:
        sys.exit(0)
    conditions = ["key = %s" % jql_text(key), "project = %s" % jql_text(setting("PROJECT"))] + scope
    issues, _ = search(" AND ".join(conditions), ["summary"], 1)
    sys.exit(0 if issues else 1)


# --- writing


def cmd_create(args):
    kind, title, rest = args[0], args[1], args[2:]
    options = {"size": "", "priority": "", "area": "", "type": "", "blocked-by": "", "parent": "", "body": ""}
    for i in range(0, len(rest), 2):
        name = rest[i][2:] if rest[i].startswith("--") else ""
        if name not in options or i + 1 >= len(rest):
            fail("unknown option %s" % rest[i], 2)
        options[name] = rest[i + 1]
    fields = custom_fields()
    blockers = [b for b in options["blocked-by"].split(",") if b]
    foreign = [b for b in blockers if not b.startswith(PREFIX)]
    jira_blockers = [b for b in blockers if b.startswith(PREFIX)]
    body = with_blockers(options["body"], foreign)
    data = {"project": {"key": setting("PROJECT")}, "summary": title,
            "issuetype": {"name": options["type"] or type_names().get(kind, type_names()["task"])}, "labels": []}
    if body.strip():
        data["description"] = to_document(body)
    if options["size"] and "size" in fields:
        data[fields["size"]["id"]] = field_input(fields["size"], options["size"])
    elif options["size"]:
        data["labels"].append("size:" + options["size"])
    if options["priority"]:
        data["priority"] = {"name": options["priority"]}
    if options["area"] and "area" in fields:
        data[fields["area"]["id"]] = field_input(fields["area"], options["area"])
    elif options["area"]:
        sys.stderr.write("flow: jira.fields.area is not set, so the new issue has no area %s\n" % options["area"])
    if options["parent"]:
        data["parent"] = {"key": key_of(options["parent"])}
    status, made = call("POST", "/rest/api/3/issue", {"fields": data}, once=True)
    expect(status, made, "create the issue")
    unlinked = [b for b in jira_blockers if not linked(b, made["key"])]
    if unlinked:
        sys.stderr.write("flow: Jira refused the Blocks link from %s, so the description of %s%s names it\n"
                         % (", ".join(unlinked), PREFIX, made["key"]))
        status, answer = call("PUT", "/rest/api/3/issue/" + made["key"],
                              {"fields": {"description": to_document(with_blockers(options["body"], foreign + unlinked))}})
        expect(status, answer, "record the blockers of %s%s" % (PREFIX, made["key"]))
    print(PREFIX + made["key"])


def with_blockers(body, blockers):
    return body + ("\n\nBlocked by: %s" % ", ".join(blockers) if blockers else "")


def linked(blocker, key):
    link = {"type": {"name": "Blocks"}, "inwardIssue": {"key": key_of(blocker)}, "outwardIssue": {"key": key}}
    status, _ = call("POST", "/rest/api/3/issueLink", link, once=True)
    return status // 100 == 2


def merged_state(current, pairs):
    for key, value in pairs:
        if key in ("touches", "changes"):
            current[key] = [t for t in value.split(",") if t.strip()]
        elif key == "attempts":
            current[key] = int(value or 0)
        else:
            current[key] = value
    current.setdefault("gate", "none")
    return current


def cmd_write_state(args):
    key, pairs = key_of(args[0]), []
    for pair in args[1:]:
        if "=" not in pair:
            fail("expected key=value, got %s" % pair, 2)
        name, value = pair.split("=", 1)
        if name.replace("-", "_") not in STATE_KEYS:
            fail("unknown state key %s" % name, 2)
        pairs.append((name.replace("-", "_"), value))
    fields = custom_fields()
    issue = read_issue(key, fields)
    labels = issue["fields"].get("labels") or []
    changes = []
    for name, value in pairs:
        prefix = LABEL_PREFIXES.get(name)
        if not prefix or (name == "size" and "size" in fields):
            continue
        changes += [{"remove": l} for l in labels if l.startswith(prefix) and l != prefix + value]
        if value and value != "none" and prefix + value not in labels:
            changes.append({"add": prefix + value})
    update = {"update": {"labels": changes}} if changes else {}
    size = next((v for n, v in pairs if n == "size"), None)
    if size is not None and "size" in fields:
        update["fields"] = {fields["size"]["id"]: field_input(fields["size"], size) if size else None}
    if update:
        status, answer = call("PUT", "/rest/api/3/issue/" + key, update)
        expect(status, answer, "write the labels of %s%s" % (PREFIX, key))
    state = merged_state(dict((issue.get("properties") or {}).get(STATE_PROPERTY) or {}), pairs)
    status, answer = call("PUT", "/rest/api/3/issue/%s/properties/%s" % (key, STATE_PROPERTY), state)
    expect(status, answer, "write the state of %s%s" % (PREFIX, key))


def comment(key, text):
    status, answer = call("POST", "/rest/api/3/issue/%s/comment" % key, {"body": to_document(text)}, once=True)
    expect(status, answer, "comment on %s%s" % (PREFIX, key))


def cmd_comment(args):
    comment(key_of(args[0]), args[1])


def cmd_close(args):
    key = key_of(args[0])
    if len(args) > 1 and args[1]:
        comment(key, args[1])
    status, answer = call("GET", "/rest/api/3/issue/%s/transitions" % key)
    if status == 404:
        fail("no such item %s%s" % (PREFIX, key))
    expect(status, answer, "read the transitions of %s%s" % (PREFIX, key))
    wanted = setting("DONE")
    done = next((t for t in answer.get("transitions") or []
                 if (t.get("name") == wanted if wanted else (t.get("name") or "").lower() == "done")), None)
    if not done:
        fail("%s%s has no transition named %s; set jira.transitions.done" % (PREFIX, key, wanted or "Done"))
    status, answer = call("POST", "/rest/api/3/issue/%s/transitions" % key, {"transition": {"id": done["id"]}}, once=True)
    expect(status, answer, "close %s%s" % (PREFIX, key))


def cmd_remote_link(args):
    key, url = key_of(args[0]), args[1]
    link = {"globalId": "flow-pr=" + url, "object": {"url": url, "title": "PR: " + url}}
    status, answer = call("POST", "/rest/api/3/issue/%s/remotelink" % key, link)
    expect(status, answer, "link the PR to %s%s" % (PREFIX, key))


# --- the owner's answers and the names a new item may use


def answerers():
    """The account ids and emails whose /answer counts: jira.answer_from, else the token's own user."""
    named = [n.strip() for n in setting("ANSWER_FROM").split(",") if n.strip()]
    if named:
        return set(named)
    status, me = call("GET", "/rest/api/3/myself")
    expect(status, me, "read the user the API token belongs to")
    return {me.get("accountId", ""), me.get("emailAddress", "")} - {""}


def comments_of(key):
    found, start = [], 0
    while True:
        status, page = call("GET", "/rest/api/3/issue/%s/comment" % key,
                            query={"startAt": start, "maxResults": PAGE_SIZE, "orderBy": "created"})
        expect(status, page, "read the comments of %s%s" % (PREFIX, key))
        batch = page.get("comments") or []
        found += batch
        start += len(batch)
        if not batch or start >= page.get("total", 0):
            return found


def answer_after_gate(comments, allowed):
    """The text of the first /answer by an allowed author after the latest gate comment, or None."""
    texts = [from_document(c.get("body")).strip() for c in comments]
    gate_at = max([n for n, text in enumerate(texts) if text.startswith(GATE_COMMENT)], default=-1)
    if gate_at < 0:
        return None
    for comment, text in list(zip(comments, texts))[gate_at + 1:]:
        author = comment.get("author") or {}
        by_allowed = allowed & {author.get("accountId", ""), author.get("emailAddress", "")}
        if text.split(None, 1)[:1] == [ANSWER_WORD] and by_allowed:
            return text[len(ANSWER_WORD):].strip() or "as recommended"
    return None


def cmd_answers(args):
    if args:
        fail("answers takes no arguments", 2)
    conditions = ['project = "%s"' % setting("PROJECT")] + scope_conditions() + ["statusCategory != Done"]
    issues, _ = search(" AND ".join(conditions) + " ORDER BY created DESC", ["labels"], int(setting("LIMIT", "500")))
    gated = [i for i in issues if flow_state(i, i["fields"].get("labels") or [], {})["gate"] not in UNANSWERABLE_GATES]
    if not gated:
        return
    allowed = answerers()
    for issue in gated:
        text = answer_after_gate(comments_of(issue["key"]), allowed)
        if text is not None:
            print(json.dumps({"id": PREFIX + issue["key"], "text": text}))


def issue_types():
    status, project = call("GET", "/rest/api/3/project/" + setting("PROJECT"))
    expect(status, project, "read the Jira project %s" % setting("PROJECT"))
    return [t for t in project.get("issueTypes") or [] if not t.get("subtask")]


def area_options(types, area):
    """The allowed values of the area field on the screen that creates a task; none for a text field."""
    task = next((t for t in types if t.get("name") == type_names()["task"]), None)
    if not task or area["type"] != "option":
        return []
    found = createmeta_field(task, area["id"]) or {}
    return [v.get("value") or v.get("name") for v in found.get("allowedValues") or [] if v.get("value") or v.get("name")]


def createmeta_field(issue_type, field_id):
    """The field as the create screen of the type has it, page by page until it turns up; None when no page has it."""
    path = "/rest/api/3/issue/createmeta/%s/issuetypes/%s" % (setting("PROJECT"), issue_type["id"])
    start = 0
    while True:
        status, page = call("GET", path, query={"startAt": start, "maxResults": PAGE_SIZE})
        expect(status, page, "read the fields a new %s takes" % issue_type["name"])
        # The docs name the list "results"; Jira Cloud answers with "fields". Either is taken.
        batch = page.get("fields") or page.get("results") or []
        found = next((f for f in batch if f.get("fieldId") == field_id), None)
        start += len(batch)
        if found is not None or not batch or page.get("isLast") or start >= page.get("total", 0):
            return found


def cmd_vocabulary(args):
    if args:
        fail("vocabulary takes no arguments", 2)
    types = issue_types()
    area = custom_fields().get("area")
    print(json.dumps({"types": [t["name"] for t in types], "areas": area_options(types, area) if area else []}))


def main():
    if len(sys.argv) < 2:
        fail(__doc__.strip().splitlines()[0], 2)
    command, args = sys.argv[1], sys.argv[2:]
    commands = {"list": cmd_list, "read": cmd_read, "in-scope": cmd_in_scope, "create": cmd_create, "write-state": cmd_write_state,
                "comment": cmd_comment, "close": cmd_close, "remote-link": cmd_remote_link,
                "answers": cmd_answers, "vocabulary": cmd_vocabulary}
    if command not in commands:
        fail("unknown command %s" % command, 2)
    commands[command](args)


main()

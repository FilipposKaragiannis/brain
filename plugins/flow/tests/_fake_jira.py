"""The fake Jira Cloud behind fake-jira.sh: one project in a JSON file, answering the REST v3 calls
the Jira adapter makes, as curl prints them with -w "\\n%{http_code}". Any other call answers 404
and says so on stderr. A Blocks link posted with inwardIssue A and outwardIssue B means A blocks B:
A reads it back as an outwardIssue B ("blocks"), B as an inwardIssue A ("is blocked by").
Comments keep their author, the user the -K login names (/rest/api/3/myself answers the same), so
answers.sh can tell the owner's /answer from anyone else's. The project (types, plus a sub-task
type) and the createmeta of each type (the option fields' allowedValues) feed vocabulary.sh; the
createmeta answers in pages of at most createmeta_page fields (default 50), as Jira caps them. A
search reads the JQL clauses in JQL_CLAUSES, ANDed, and refuses any other; an issue's assignee is a
fields.assignee object, as Jira returns one."""
import json, re, sys
from functools import reduce
from urllib.parse import parse_qs, urlsplit

db_path, args = sys.argv[1], sys.argv[2:]
data = json.load(open(db_path))
login = sys.stdin.read() if args[args.index("-K") + 1:args.index("-K") + 2] == ["-"] else ""
method = args[args.index("-X") + 1] if "-X" in args else "GET"
body = json.load(open(args[args.index("--data-binary") + 1][1:])) if "--data-binary" in args else None
url = urlsplit([a for a in args if a.startswith("https://")][-1])
path, query = url.path, {k: v[0] for k, v in parse_qs(url.query).items()}
project = data.setdefault("project", "WID")
issues = data.setdefault("issues", {})
links = data.setdefault("links", [])
fields_known = data.setdefault("fields", [
    {"id": "summary", "name": "Summary", "custom": False, "schema": {"type": "string"}},
    {"id": "customfield_10040", "name": "Size", "custom": True, "schema": {"type": "option"}},
    {"id": "customfield_10041", "name": "Area", "custom": True, "schema": {"type": "option"}}])
options = data.setdefault("options", {"customfield_10040": ["S", "M", "L"], "customfield_10041": ["Bots", "Debugging"]})
types = data.setdefault("types", ["Epic", "Task", "Bug", "Story", "Feature"])
priorities = data.setdefault("priorities", ["P0", "P1", "P2", "P3"])
transitions = data.setdefault("transitions", [{"id": "11", "name": "To Do", "category": "new"},
                                              {"id": "21", "name": "In Progress", "category": "indeterminate"},
                                              {"id": "31", "name": "Done", "category": "done"}])


def user_of(login_line):
    """The account the login belongs to: its email, and an account id made from it."""
    email = re.search(r'^user = "([^:"]+):', login_line, re.M).group(1)
    return {"accountId": "acct-" + email.split("@")[0], "emailAddress": email, "displayName": email.split("@")[0]}


def answer(status, payload=None):
    json.dump(data, open(db_path, "w"))
    sys.stdout.write((json.dumps(payload) if payload is not None else "") + "\n%d" % status)
    sys.exit(0)


def refuse(status, message):
    answer(status, {"errorMessages": [message], "errors": {}})


def status_of(issue):
    return issue["fields"]["status"]


def view(issue, wanted, properties):
    shown = {k: v for k, v in issue["fields"].items() if k in wanted}
    if "issuelinks" in wanted:
        shown["issuelinks"] = []
        for link in links:
            if issue["key"] not in (link["inward"], link["outward"]):
                continue
            side, other = ("outwardIssue", link["outward"]) if link["inward"] == issue["key"] else ("inwardIssue", link["inward"])
            shown["issuelinks"].append({"type": {"name": "Blocks", "inward": "is blocked by", "outward": "blocks"},
                                        side: {"key": other, "fields": {"status": status_of(issues[other])}}})
    return {"key": issue["key"], "fields": shown,
            "properties": {p: issue["properties"][p] for p in properties if p in issue["properties"]}}


def quoted(text):
    return [unquote(v) for v in re.findall(r'"((?:[^"\\]|\\.)*)"', text)]


def unquote(text):
    return text.replace('\\"', '"').replace("\\\\", "\\")


def assigned(issue, who):
    person = issue["fields"].get("assignee") or {}
    return who in (person.get("emailAddress"), person.get("accountId"), person.get("displayName"))


# The JQL the adapter and the tests send, each clause with the issues it keeps; the clauses are
# ANDed, and the search refuses any other text. The login is the user currentUser() stands for.
signed_in = re.search(r'^user = "([^:"]+):', login, re.M)
me = signed_in.group(1) if signed_in else ""
JQL_CLAUSES = [
    (re.compile(r'project = "([^"]+)"'), lambda i, m: i["key"].startswith(m.group(1) + "-")),
    (re.compile(r"parent = ([A-Z][A-Z0-9_]*-\d+)"), lambda i, m: (i["fields"].get("parent") or {}).get("key") == m.group(1)),
    (re.compile(r"parent in \(([^)]*)\)"), lambda i, m: (i["fields"].get("parent") or {}).get("key") in [k.strip() for k in m.group(1).split(",")]),
    (re.compile(r"statusCategory != Done"), lambda i, m: status_of(i)["statusCategory"]["key"] != "done"),
    (re.compile(r"assignee = currentUser\(\)"), lambda i, m: assigned(i, me)),
    (re.compile(r'assignee = ("(?:[^"\\]|\\.)*")'), lambda i, m: assigned(i, quoted(m.group(1))[0])),
    (re.compile(r'status (?:in \(([^)]*)\)|= ("(?:[^"\\]|\\.)*"))'),
     lambda i, m: status_of(i)["name"].lower() in [s.lower() for s in quoted(m.group(1) or m.group(2))]),
    (re.compile(r'labels (?:in \(([^)]*)\)|= ("(?:[^"\\]|\\.)*"))'),
     lambda i, m: bool(set(i["fields"].get("labels") or []) & set(quoted(m.group(1) or m.group(2))))),
]


def check_field(fields, field_id):
    if field_id in fields and fields[field_id] is not None and fields[field_id].get("value") not in options.get(field_id, []):
        refuse(400, "option %s is not valid for %s" % (fields[field_id], field_id))


if not re.search(r'^user = "[^:"]+:[^"]+"$', login, re.M):
    refuse(401, "Client must be authenticated to access this resource.")
if path == "/rest/api/3/field" and method == "GET":
    answer(200, fields_known)
if path == "/rest/api/3/myself" and method == "GET":
    answer(200, user_of(login))
if path == "/rest/api/3/project/" + project and method == "GET":
    answer(200, {"key": project, "issueTypes": [{"id": str(10000 + n), "name": t, "subtask": False} for n, t in enumerate(types)]
                 + [{"id": "10900", "name": "Subtask", "subtask": True}]})
m = re.match(r"/rest/api/3/issue/createmeta/%s/issuetypes/(\d+)$" % project, path)
if m and method == "GET":
    every = [{"fieldId": f, "name": f, "allowedValues": [{"id": str(n), "value": v} for n, v in enumerate(values)]}
             for f, values in options.items()]
    start, size = int(query.get("startAt", 0)), min(int(query.get("maxResults", 50)), data.get("createmeta_page", 50))
    answer(200, {"startAt": start, "maxResults": size, "total": len(every), "fields": every[start:start + size]})
if path == "/rest/api/3/issue" and method == "POST":
    f = body["fields"]
    if f["project"]["key"] != project:
        refuse(400, "no project %s" % f["project"]["key"])
    if f["issuetype"]["name"] not in types:
        refuse(400, "Specify a valid issue type")
    if f.get("priority") and f["priority"]["name"] not in priorities:
        refuse(400, "Specify a valid priority")
    if f.get("parent") and f["parent"]["key"] not in issues:
        refuse(400, "The parent issue does not exist")
    for field_id in options:
        check_field(f, field_id)
    data["next"] = data.get("next", 0) + 1
    key = "%s-%d" % (project, data["next"])
    fields = {k: v for k, v in f.items() if k != "project"}
    fields["status"] = {"name": "To Do", "statusCategory": {"key": "new"}}
    fields.setdefault("labels", [])
    fields.setdefault("priority", None)
    issues[key] = {"key": key, "fields": fields, "properties": {}, "comments": [], "remotelinks": []}
    answer(201, {"id": str(data["next"]), "key": key})
if path == "/rest/api/3/issueLink" and method == "POST":
    if body["type"]["name"] != "Blocks" or body["inwardIssue"]["key"] not in issues or body["outwardIssue"]["key"] not in issues:
        refuse(404, "No issue link type or issue found")
    links.append({"inward": body["inwardIssue"]["key"], "outward": body["outwardIssue"]["key"]})
    answer(201)
if path == "/rest/api/3/search/jql" and method == "POST":
    jql = body["jql"]
    rows = sorted(issues.values(), key=lambda i: int(i["key"].rsplit("-", 1)[1]), reverse="ORDER BY created DESC" in jql)
    where = jql.split(" ORDER BY ")[0]
    for clause in JQL_CLAUSES:
        for m in clause[0].finditer(where):
            rows = [i for i in rows if clause[1](i, m)]
    leftover = re.sub(r"\bAND\b|[()\s]", "", reduce(lambda text, clause: clause[0].sub("", text), JQL_CLAUSES, where))
    if leftover:
        refuse(400, "fake jira: unknown JQL in %s" % jql)
    start = int(body.get("nextPageToken") or 0)
    page = rows[start:start + body.get("maxResults", 50)]
    last = start + len(page) >= len(rows)
    out = {"issues": [view(i, body.get("fields", []), body.get("properties", [])) for i in page], "isLast": last}
    if not last:
        out["nextPageToken"] = str(start + len(page))
    answer(200, out)
m = re.match(r"/rest/api/3/issue/([A-Z][A-Z0-9_]*-\d+)(/.*)?$", path)
if m:
    issue, rest = issues.get(m.group(1)), m.group(2) or ""
    if not issue:
        refuse(404, "Issue does not exist or you do not have permission to see it.")
    if rest == "" and method == "GET":
        answer(200, view(issue, query.get("fields", "").split(","), query.get("properties", "").split(",")))
    if rest == "" and method == "PUT":
        for change in (body.get("update") or {}).get("labels", []):
            if "add" in change and change["add"] not in issue["fields"]["labels"]:
                issue["fields"]["labels"].append(change["add"])
            if "remove" in change:
                issue["fields"]["labels"] = [l for l in issue["fields"]["labels"] if l != change["remove"]]
        for field_id in options:
            check_field(body.get("fields") or {}, field_id)
        issue["fields"].update(body.get("fields") or {})
        answer(204)
    m = re.match(r"/properties/([\w.-]+)$", rest)
    if m and method == "PUT":
        status = 200 if m.group(1) in issue["properties"] else 201
        issue["properties"][m.group(1)] = body
        answer(status)
    if rest == "/comment" and method == "POST":
        issue["comments"].append({"id": str(len(issue["comments"]) + 1), "body": body["body"], "author": user_of(login)})
        answer(201, issue["comments"][-1])
    if rest == "/comment" and method == "GET":
        start, size = int(query.get("startAt", 0)), int(query.get("maxResults", 50))
        answer(200, {"startAt": start, "maxResults": size, "total": len(issue["comments"]), "comments": issue["comments"][start:start + size]})
    if rest == "/transitions" and method == "GET":
        answer(200, {"transitions": [{"id": t["id"], "name": t["name"], "to": {"name": t["name"], "statusCategory": {"key": t["category"]}}}
                                     for t in transitions]})
    if rest == "/transitions" and method == "POST":
        chosen = next((t for t in transitions if t["id"] == body["transition"]["id"]), None)
        if not chosen:
            refuse(400, "Transition id %s is not valid for this issue." % body["transition"]["id"])
        issue["fields"]["status"] = {"name": chosen["name"], "statusCategory": {"key": chosen["category"]}}
        answer(204)
    if rest == "/remotelink" and method == "POST":
        kept = [l for l in issue["remotelinks"] if l.get("globalId") != body.get("globalId")]
        replaced = len(kept) < len(issue["remotelinks"])
        issue["remotelinks"] = kept + [body]
        answer(200 if replaced else 201, {"id": len(issue["remotelinks"])})
sys.stderr.write("fake jira: unknown call %s %s\n" % (method, path))
refuse(404, "fake jira: unknown call %s %s" % (method, path))

"""The fake Jira Cloud behind fake-jira.sh: one project in a JSON file, answering the REST v3 calls
the Jira adapter makes, as curl prints them with -w "\\n%{http_code}". Any other call answers 404
and says so on stderr."""
import json, re, sys
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
            side, other = ("inwardIssue", link["outward"]) if link["inward"] == issue["key"] else ("outwardIssue", link["inward"])
            shown["issuelinks"].append({"type": {"name": "Blocks", "inward": "is blocked by", "outward": "blocks"},
                                        side: {"key": other, "fields": {"status": status_of(issues[other])}}})
    return {"key": issue["key"], "fields": shown,
            "properties": {p: issue["properties"][p] for p in properties if p in issue["properties"]}}


def check_field(fields, field_id):
    if field_id in fields and fields[field_id] is not None and fields[field_id].get("value") not in options.get(field_id, []):
        refuse(400, "option %s is not valid for %s" % (fields[field_id], field_id))


if not re.search(r'^user = "[^:"]+:[^"]+"$', login, re.M):
    refuse(401, "Client must be authenticated to access this resource.")
if path == "/rest/api/3/field" and method == "GET":
    answer(200, fields_known)
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
    m = re.match(r'project = "([^"]+)"', jql)
    rows = [i for i in rows if i["key"].startswith(m.group(1) + "-")] if m else rows
    m = re.match(r"parent = (\S+)", jql)
    rows = [i for i in rows if (i["fields"].get("parent") or {}).get("key") == m.group(1)] if m else rows
    if "statusCategory != Done" in jql:
        rows = [i for i in rows if status_of(i)["statusCategory"]["key"] != "done"]
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
        issue["comments"].append({"id": str(len(issue["comments"]) + 1), "body": body["body"]})
        answer(201, issue["comments"][-1])
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

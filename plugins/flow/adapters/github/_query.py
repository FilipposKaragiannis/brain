"""Issues as raw adapter input, through GraphQL. See list.sh and read.sh.

  _query.py list <repo> <marker> <open|all> <limit>
  _query.py read <repo> <marker> <number>

One paged query returns each issue with its labels, type, native parent, blockers, issue field
values and project items, so a list costs one call per page, not one per issue. The field values
are asked for only when GH_SIZE_FIELD or GH_PRIORITY_FIELD is set, and the project items only when
GH_PROJECT is set, because they need the read:project scope a default login lacks. The state
comment is read only for issues that carry a flow label, as before. Prints one JSON object per
line. FLOW_GH_PAGE sets the page size (tests)."""
import json, os, re, subprocess, sys

WANT_FIELDS = bool(os.environ.get("GH_SIZE_FIELD") or os.environ.get("GH_PRIORITY_FIELD"))
WANT_PROJECT = bool(os.environ.get("GH_PROJECT"))
BASE = """
  number title body state url
  labels(first: 50) { nodes { name } }
  issueType { name }
  parent { number }
  blockedBy(first: 50) { nodes { number state } }"""
FIELD_VALUES = """
  issueFieldValues(first: 20) { nodes {
    ... on IssueFieldSingleSelectValue { name field { ... on IssueFieldSingleSelect { name } } }
    ... on IssueFieldTextValue { value field { ... on IssueFieldText { name } } }
    ... on IssueFieldNumberValue { value field { ... on IssueFieldNumber { name } } }
    ... on IssueFieldDateValue { value field { ... on IssueFieldDate { name } } }
  } }"""
PROJECT_ITEMS = """
  projectItems(first: 10) { nodes { id project { number }
    fieldValueByName(name: "Status") { ... on ProjectV2ItemFieldSingleSelectValue { name } } } }"""
FIELDS = "\nfragment F on Issue {" + BASE + (FIELD_VALUES if WANT_FIELDS else "") + \
    (PROJECT_ITEMS if WANT_PROJECT else "") + "\n}"
LIST = """query($owner: String!, $name: String!, $first: Int!, $after: String, $states: [IssueState!]) {
  repository(owner: $owner, name: $name) {
    issues(first: $first, after: $after, states: $states, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor } nodes { ...F } } } }""" + FIELDS
READ = """query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { issue(number: $number) { ...F } } }""" + FIELDS


def gh(*args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True)
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        return None
    return json.loads(out.stdout) if out.stdout.strip() else None


def graphql(query, **variables):
    args = ["api", "graphql", "-f", "query=" + query]
    for key, value in variables.items():
        if value is None:
            continue
        args += ["-F" if isinstance(value, int) else "-f", "%s=%s" % (key, value)]
    return gh(*args)


def state_comment(repo, issue, marker):
    if not any(l["name"].split(":")[0] in ("step", "gate", "wt", "flow") for l in issue["labels"]):
        return {}
    for c in gh("api", "repos/%s/issues/%d/comments?per_page=100" % (repo, issue["number"])) or []:
        if marker in c.get("body", ""):
            m = re.search(r"```json\n(.*?)\n```", c["body"], re.S)
            try:
                return json.loads(m.group(1)) if m else {}
            except ValueError:
                return {}
    return {}


def raw(repo, node, marker):
    fields = {}
    for v in (node.get("issueFieldValues") or {}).get("nodes", []):
        name = (v.get("field") or {}).get("name")
        if name:
            fields[name] = v.get("name", v.get("value"))
    issue = {
        "number": node["number"], "title": node["title"], "body": node["body"] or "",
        "state": node["state"], "url": node["url"],
        "labels": [{"name": l["name"]} for l in node["labels"]["nodes"]],
        "type": (node.get("issueType") or {}).get("name", ""),
        "parent": node.get("parent"),
        "blocked_by": [{"number": b["number"], "state": b["state"].lower()} for b in node["blockedBy"]["nodes"]],
        "fields": fields,
        "project_items": [{"id": p["id"], "project": p["project"]["number"],
                           "status": (p.get("fieldValueByName") or {}).get("name", "")}
                          for p in (node.get("projectItems") or {}).get("nodes", [])],
    }
    issue["state_comment"] = state_comment(repo, issue, marker)
    return issue


def main():
    mode, repo, marker = sys.argv[1], sys.argv[2], sys.argv[3]
    owner, name = repo.split("/", 1)
    if mode == "read":
        data = graphql(READ, owner=owner, name=name, number=int(sys.argv[4]))
        node = data and data["data"]["repository"]["issue"]
        if not node:
            sys.exit(1)
        print(json.dumps(raw(repo, node, marker)))
        return
    states = "OPEN" if sys.argv[4] == "open" else None
    what = "open issues" if states else "issues"
    limit, page, after, seen = int(sys.argv[5]), int(os.environ.get("FLOW_GH_PAGE", "50")), None, 0
    while seen < limit:
        data = graphql(LIST, owner=owner, name=name, first=min(page, limit - seen), after=after, states=states)
        if not data:
            sys.exit(1)
        issues = data["data"]["repository"]["issues"]
        for node in issues["nodes"]:
            print(json.dumps(raw(repo, node, marker)))
            seen += 1
        if not issues["pageInfo"]["hasNextPage"]:
            return
        after = issues["pageInfo"]["endCursor"]
    sys.stderr.write("flow: stopped at github.limit %d %s; raise it in .flow/config.yaml\n" % (limit, what))


main()

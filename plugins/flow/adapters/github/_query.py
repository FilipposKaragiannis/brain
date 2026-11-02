"""Issues as raw adapter input, through GraphQL. See list.sh and read.sh.

  _query.py list <repo> <marker> <open|all> <limit>   (narrowed by FLOW_PICK_*, see picked)
  _query.py read <repo> <marker> <number>

One paged query returns each issue with its labels, type, native parent, blockers, open sub-issue
count, issue field
values and project items, so a list costs one call per page, not one per issue. The field values
are asked for only when GH_SIZE_FIELD, GH_PRIORITY_FIELD or GH_AREA_FIELD is set, and the project items only when
GH_PROJECT is set, because they need the read:project scope a default login lacks. The state
comment is read for a single issue, and in a list only for issues that carry a flow label: an
unstarted item keeps the last gate's answer there with no label. Prints one JSON object per
line. FLOW_GH_PAGE sets the page size (tests). A list cut at the limit says so and exits 0, or 1
with FLOW_LIST_WHOLE set, for a caller that needs every item (a board graph). A call GitHub fails with a 5xx is tried again
(_call.py); a call that still fails ends the read with a message, never with half an item."""
import json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _call  # noqa: E402

WANT_FIELDS = bool(os.environ.get("GH_SIZE_FIELD") or os.environ.get("GH_PRIORITY_FIELD") or os.environ.get("GH_AREA_FIELD"))
WANT_PROJECT = bool(os.environ.get("GH_PROJECT"))
BASE = """
  number title body state url
  labels(first: 50) { nodes { name } }
  assignees(first: 20) { nodes { login } }
  issueType { name }
  parent { number }
  blockedBy(first: 50) { nodes { number state } }
  subIssuesSummary { total completed }"""
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
SEARCH = """query($q: String!, $first: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $first, after: $after) {
    pageInfo { hasNextPage endCursor } nodes { ...F } } }""" + FIELDS


def pick_values(name):
    return {v.strip().lower() for v in os.environ.get("FLOW_PICK_" + name, "").split(",") if v.strip()}


# The pick filter of `list --pick` (pick_filter in lib/flow.sh; list.sh turns `me` into the gh
# user's login): a login, label names and issue states (open, closed), compared without case as
# GitHub does. The kinds are matched in list.sh, on the built item. A query is GitHub search
# qualifiers, sent as written within the repository's issues.
PICK_ASSIGNEE = os.environ.get("FLOW_PICK_ASSIGNEE", "").strip().lower()
PICK_LABELS = pick_values("LABELS")
PICK_STATUS = pick_values("STATUS")
PICK_QUERY = os.environ.get("FLOW_PICK_QUERY", "").strip()


def picked(node):
    if PICK_ASSIGNEE and PICK_ASSIGNEE not in {a["login"].lower() for a in node["assignees"]["nodes"]}:
        return False
    if PICK_LABELS and not PICK_LABELS & {l["name"].lower() for l in node["labels"]["nodes"]}:
        return False
    return not PICK_STATUS or node["state"].lower() in PICK_STATUS


def issue_page(owner, name, states, first, after):
    """One page of the repository's issues, or of the search PICK_QUERY names; None on a failed call."""
    if PICK_QUERY:
        query = "repo:%s/%s is:issue %s%s" % (owner, name, "is:open " if states else "", PICK_QUERY)
        data = graphql(SEARCH, q=query, first=first, after=after)
        return data and data["data"]["search"]
    data = graphql(LIST, owner=owner, name=name, first=first, after=after, states=states)
    return data and data["data"]["repository"]["issues"]


def gh(*args):
    out = _call.gh(args)
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


def state_comment(repo, issue, marker, always=False):
    if not always and not any(l["name"].split(":")[0] in ("step", "gate", "wt", "flow") for l in issue["labels"]):
        return {}
    pages = gh("api", "--paginate", "--slurp", "repos/%s/issues/%d/comments?per_page=100" % (repo, issue["number"]))
    if pages is None:
        # Without the comment the item would read as unstarted, with no attempts, no PR and no
        # touches: a wrong answer, so no answer. A read ends; a list leaves the issue out, so it
        # is not picked, shown or synced this round, and goes on.
        if always:
            sys.exit("flow: cannot read the comments of gh#%d" % issue["number"])
        sys.stderr.write("flow: cannot read the comments of gh#%d, so the list leaves it out\n" % issue["number"])
        return None
    for c in [c for page in pages for c in page]:
        if marker in c.get("body", ""):
            m = re.search(r"```json\n(.*?)\n```", c["body"], re.S)
            try:
                return json.loads(m.group(1)) if m else {}
            except ValueError:
                return {}
    return {}


def raw(repo, node, marker, always=False):
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
        "open_children": (lambda s: s["total"] - s["completed"])(node.get("subIssuesSummary") or {"total": 0, "completed": 0}),
        "project_items": [{"id": p["id"], "project": p["project"]["number"],
                           "status": (p.get("fieldValueByName") or {}).get("name", "")}
                          for p in (node.get("projectItems") or {}).get("nodes", [])],
    }
    issue["state_comment"] = state_comment(repo, issue, marker, always)
    return None if issue["state_comment"] is None else issue


def main():
    mode, repo, marker = sys.argv[1], sys.argv[2], sys.argv[3]
    owner, name = repo.split("/", 1)
    if mode == "read":
        data = graphql(READ, owner=owner, name=name, number=int(sys.argv[4]))
        node = data and data["data"]["repository"]["issue"]
        if not node:
            sys.exit(1)
        print(json.dumps(raw(repo, node, marker, always=True)))
        return
    states = "OPEN" if sys.argv[4] == "open" else None
    what = "open issues" if states else "issues"
    limit, page, after, seen = int(sys.argv[5]), int(os.environ.get("FLOW_GH_PAGE", "50")), None, 0
    while seen < limit:
        issues = issue_page(owner, name, states, min(page, limit - seen), after)
        if not issues:
            sys.exit(1)
        for node in issues["nodes"]:
            # A node the filter leaves out costs no state comment read.
            issue = raw(repo, node, marker) if picked(node) else None
            if issue is not None:
                print(json.dumps(issue))
            seen += 1
        if not issues["pageInfo"]["hasNextPage"]:
            return
        after = issues["pageInfo"]["endCursor"]
    sys.stderr.write("flow: stopped at github.limit %d %s; raise it in .flow/config.yaml\n" % (limit, what))
    if os.environ.get("FLOW_LIST_WHOLE"):
        sys.exit(1)


main()

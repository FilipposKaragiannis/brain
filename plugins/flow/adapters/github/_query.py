"""Issues as raw adapter input, through GraphQL. See list.sh and read.sh.

  _query.py list <repo> <marker> <open|all> <limit>   (narrowed by FLOW_SCOPE_* and FLOW_PICK_*, see matches)
  _query.py read <repo> <marker> <number>
  _query.py in-scope <repo> <marker> <number> <limit> (exit 0 inside FLOW_SCOPE_*, 1 outside, 3 when the search fails)

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
MEMBERS = """query($q: String!, $first: Int!, $after: String) {
  search(query: $q, type: ISSUE, first: $first, after: $after) {
    pageInfo { hasNextPage endCursor } nodes { ... on Issue {
      number state labels(first: 50) { nodes { name } } assignees(first: 20) { nodes { login } } } } } }"""


def filter_values(prefix, name):
    return {value.strip().lower() for value in os.environ.get(prefix + name, "").split(",") if value.strip()}


def filter_rules(prefix):
    """The neutral fields of a filter (FLOW_PICK_ for `list --pick`, pick_filter in lib/flow.sh;
    FLOW_SCOPE_ for github.scope, scope_filter; list.sh turns `me` into the gh user's login): a
    login, label names and issue states (open, closed), compared without case as GitHub does. The
    kinds are matched on the built item, in list.sh and in-scope.sh."""
    assignee = os.environ.get(prefix + "ASSIGNEE", "").strip().lower()
    return {"assignee": {assignee} if assignee else set(),
            "labels": filter_values(prefix, "LABELS"), "status": filter_values(prefix, "STATUS")}


# A query is GitHub search qualifiers, sent as written within the repository's issues.
PICK_RULES, PICK_QUERY = filter_rules("FLOW_PICK_"), os.environ.get("FLOW_PICK_QUERY", "").strip()
SCOPE_RULES, SCOPE_QUERY = filter_rules("FLOW_SCOPE_"), os.environ.get("FLOW_SCOPE_QUERY", "").strip()
ISSUE_STATES = {"open", "closed"}
PAGE_SIZE = int(os.environ.get("FLOW_GH_PAGE", "50"))
INSIDE, OUTSIDE, UNKNOWN = 0, 1, 3


def matches(node, rules):
    have = {"assignee": {assignee["login"].lower() for assignee in node["assignees"]["nodes"]},
            "labels": {label["name"].lower() for label in node["labels"]["nodes"]},
            "status": {node["state"].lower()}}
    return all(have[field] & wanted for field, wanted in rules.items() if wanted)


def scope_qualifiers():
    """github.scope as search qualifiers: assignee:<login>, label:"a","b" (any of them), is:open or
    is:closed when the status names exactly one of them, and its query as written. A status of
    both or neither sends no qualifier; matches keeps the issues it names."""
    words = ["assignee:" + login for login in SCOPE_RULES["assignee"]]
    if SCOPE_RULES["labels"]:
        words.append("label:" + ",".join('"%s"' % label for label in sorted(SCOPE_RULES["labels"])))
    states = SCOPE_RULES["status"] & ISSUE_STATES
    if len(states) == 1:
        words.append("is:" + states.pop())
    return " ".join(words + ([SCOPE_QUERY] if SCOPE_QUERY else []))


def issue_page(owner, name, states, first, after):
    """One page of the repository's issues, or of the search github.scope and PICK_QUERY name; None
    on a failed call."""
    words = " ".join(word for word in (scope_qualifiers(), PICK_QUERY) if word)
    if words:
        query = "repo:%s/%s is:issue %s%s" % (owner, name, "is:open " if states else "", words)
        data = graphql(SEARCH, q=query, first=first, after=after)
        return data and data["data"]["search"]
    data = graphql(LIST, owner=owner, name=name, first=first, after=after, states=states)
    return data and data["data"]["repository"]["issues"]


def in_scope(owner, name, number, limit):
    """INSIDE when github.scope's search, paged up to the limit, holds the issue, OUTSIDE when not,
    UNKNOWN when a call fails; INSIDE with no call when the scope sets no qualifier and no rule. No
    state comment is read."""
    qualifiers = scope_qualifiers()
    if not qualifiers and not any(SCOPE_RULES.values()):
        return INSIDE
    query, after, seen = "repo:%s/%s is:issue %s" % (owner, name, qualifiers), None, 0
    while seen < limit:
        data = graphql(MEMBERS, q=query, first=min(PAGE_SIZE, limit - seen), after=after)
        if not data:
            return UNKNOWN
        found = data["data"]["search"]
        if any(node.get("number") == number for node in found["nodes"] if matches(node, SCOPE_RULES)):
            return INSIDE
        seen += len(found["nodes"])
        if not found["pageInfo"]["hasNextPage"]:
            return OUTSIDE
        after = found["pageInfo"]["endCursor"]
    sys.stderr.write("flow: stopped at github.limit %d issues in github.scope before gh#%d; raise it in .flow/config.yaml\n"
                     % (limit, number))
    return OUTSIDE


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
    if mode == "in-scope":
        sys.exit(in_scope(owner, name, int(sys.argv[4]), int(sys.argv[5])))
    if mode == "read":
        data = graphql(READ, owner=owner, name=name, number=int(sys.argv[4]))
        node = data and data["data"]["repository"]["issue"]
        if not node:
            sys.exit(1)
        print(json.dumps(raw(repo, node, marker, always=True)))
        return
    states = "OPEN" if sys.argv[4] == "open" else None
    what = "open issues" if states else "issues"
    limit, after, seen = int(sys.argv[5]), None, 0
    while seen < limit:
        issues = issue_page(owner, name, states, min(PAGE_SIZE, limit - seen), after)
        if not issues:
            sys.exit(1)
        for node in issues["nodes"]:
            # A node the filter leaves out costs no state comment read.
            issue = raw(repo, node, marker) if matches(node, SCOPE_RULES) and matches(node, PICK_RULES) else None
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

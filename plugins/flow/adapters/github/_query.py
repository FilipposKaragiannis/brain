"""Issues as raw adapter input, through GraphQL. See list.sh and read.sh.

  _query.py list <repo> <marker> <open|all> <limit>   (narrowed by FLOW_SCOPE_* and FLOW_PICK_*, see matches)
  _query.py read <repo> <marker> <number>
  _query.py in-scope <repo> <marker> <number> <limit> (exit 0 inside FLOW_SCOPE_*, 1 outside, 3 when the search fails)

One paged query returns each issue with its labels, type, native parent, blockers, open sub-issue
count, issue field
values and project items, so a list costs one call per page, not one per issue. The field values
are asked for only when GH_SIZE_FIELD, GH_PRIORITY_FIELD or GH_AREA_FIELD is set, and the project items only when
GH_PROJECT is set, because they need the read:project scope a default login lacks. The state
comment is read for a single issue, and in a list only for issues that carry a flow label, or for
every issue with FLOW_LIST_EVERY_STATE set (state.sh import): an unstarted item keeps the last
gate's answer there with no label. Prints one JSON object per
line. FLOW_GH_PAGE sets the page size (tests). The limit counts the issues the scope and the pick
keep, their kinds too, so issues they leave out never use it up. A list cut at the limit says so
and exits 0, or 1 with FLOW_LIST_WHOLE set, for a caller that needs every item (a board graph). A call GitHub fails with a 5xx is tried again
(_call.py); a call that still fails ends the read with a message, never with half an item."""
import json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _call  # noqa: E402

WANT_FIELDS = bool(os.environ.get("GH_SIZE_FIELD") or os.environ.get("GH_PRIORITY_FIELD") or os.environ.get("GH_AREA_FIELD"))
WANT_PROJECT = bool(os.environ.get("GH_PROJECT"))
LABELS = "labels(first: 50) { nodes { name } }"
ASSIGNEES = "assignees(first: 20) { nodes { login } }"
BASE = """
  number title body state url
  """ + LABELS + """
  """ + ASSIGNEES + """
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
      number state issueType { name } """ + LABELS + " " + ASSIGNEES + " } } } }"


def filter_values(prefix, name):
    return {value.strip().lower() for value in os.environ.get(prefix + name, "").split(",") if value.strip()}


def scope_assignee():
    """github.scope names one login: its search ANDs two assignee: qualifiers, so a list there would
    mean every one of them."""
    assignee = os.environ.get("FLOW_SCOPE_ASSIGNEE", "").strip().lower()
    return {assignee} if assignee else set()


def filter_rules(prefix, assignees):
    """The neutral fields of a filter (FLOW_PICK_ for `list --pick`, pick_filter in lib/flow.sh;
    FLOW_SCOPE_ for github.scope, scope_filter; list.sh turns `me` into the gh user's login): the
    assignees' logins, label names and issue states (open, closed), compared without case as GitHub
    does, and the kinds (kind_of)."""
    return {"assignee": assignees,
            "labels": filter_values(prefix, "LABELS"), "status": filter_values(prefix, "STATUS"),
            "kinds": filter_values(prefix, "KINDS")}


# A query is GitHub search qualifiers, sent as written within the repository's issues.
PICK_RULES = filter_rules("FLOW_PICK_", filter_values("FLOW_PICK_", "ASSIGNEE"))
PICK_QUERY = os.environ.get("FLOW_PICK_QUERY", "").strip()
SCOPE_RULES = filter_rules("FLOW_SCOPE_", scope_assignee())
SCOPE_QUERY = os.environ.get("FLOW_SCOPE_QUERY", "").strip()
ISSUE_STATES = {"open", "closed"}
PAGE_SIZE = int(os.environ.get("FLOW_GH_PAGE", "50"))
READ_EVERY_STATE = bool(os.environ.get("FLOW_LIST_EVERY_STATE"))
FLOW_LABEL_PREFIXES = ("step", "gate", "wt", "flow")
INSIDE, OUTSIDE, UNKNOWN = 0, 1, 3


def kind_of(node):
    """The flow kind of an issue: its type Epic or Bug, any other type a task; with no type, the
    label epic or bug (or kind:epic, kind:bug), else the first kind: label, else task."""
    type_name = (node.get("issueType") or {}).get("name") or ""
    if type_name:
        return {"Epic": "epic", "Bug": "bug"}.get(type_name, "task")
    labels = [label["name"] for label in node["labels"]["nodes"]]
    for kind in ("epic", "bug"):
        if kind in labels or "kind:" + kind in labels:
            return kind
    return next((label[len("kind:"):] for label in labels if label.startswith("kind:")), "task")


def matches(node, rules):
    have = {"assignee": {assignee["login"].lower() for assignee in node["assignees"]["nodes"]},
            "labels": {label["name"].lower() for label in node["labels"]["nodes"]},
            "status": {node["state"].lower()}, "kinds": {kind_of(node)}}
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


def scope_is_empty():
    """True when github.scope sets no qualifier and no rule but its kinds, which in-scope.sh
    matches on the issue it reads."""
    return not scope_qualifiers() and not any(wanted for field, wanted in SCOPE_RULES.items() if field != "kinds")


def scoped_numbers(query, limit, number):
    """The numbers of the issues github.scope's search holds and SCOPE_RULES match, page by page
    until the limit of them; None for a failed call, after which nothing more. Stopping at the
    limit says so, naming gh#number, the issue asked about."""
    after, seen = None, 0
    while True:
        response = graphql(MEMBERS, q=query, first=PAGE_SIZE, after=after)
        if not response:
            yield None
            return
        found = response["data"]["search"]
        inside = [node.get("number") for node in found["nodes"] if matches(node, SCOPE_RULES)]
        yield from inside[:limit - seen]
        seen += len(inside)
        if past_limit(seen, limit, found["pageInfo"]["hasNextPage"]):
            break
        if not found["pageInfo"]["hasNextPage"]:
            return
        after = found["pageInfo"]["endCursor"]
    sys.stderr.write("flow: stopped at github.limit %d issues in github.scope before gh#%d; raise it in .flow/config.yaml\n"
                     % (limit, number))


def past_limit(kept, limit, more):
    """True when the issues kept so far run past the limit, or reach it with more pages to read."""
    return kept > limit or (kept == limit and more)


def in_scope(owner, name, number, limit):
    """INSIDE when github.scope's search, paged up to the limit, holds the issue, OUTSIDE when not,
    UNKNOWN when a call fails; INSIDE with no call when the scope sets no qualifier and no rule. No
    state comment is read."""
    if scope_is_empty():
        return INSIDE
    query = "repo:%s/%s is:issue %s" % (owner, name, scope_qualifiers())
    for scoped_number in scoped_numbers(query, limit, number):
        if scoped_number is None:
            return UNKNOWN
        if scoped_number == number:
            return INSIDE
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


def carries_flow_label(issue):
    return any(label["name"].split(":")[0] in FLOW_LABEL_PREFIXES for label in issue["labels"])


def state_comment(repo, issue, marker, read_every, single_read):
    if not (read_every or carries_flow_label(issue)):
        return {}
    pages = gh("api", "--paginate", "--slurp", "repos/%s/issues/%d/comments?per_page=100" % (repo, issue["number"]))
    if pages is None:
        # Without the comment the item would read as unstarted, with no attempts, no PR and no
        # touches: a wrong answer, so no answer. A read ends; a list leaves the issue out, so it
        # is not picked, shown or synced this round, and goes on.
        if single_read:
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


def raw(repo, node, marker, read_every, single_read):
    fields = {}
    for v in (node.get("issueFieldValues") or {}).get("nodes", []):
        name = (v.get("field") or {}).get("name")
        if name:
            fields[name] = v.get("name", v.get("value"))
    issue = {
        "number": node["number"], "title": node["title"], "body": node["body"] or "",
        "state": node["state"], "url": node["url"],
        "labels": [{"name": l["name"]} for l in node["labels"]["nodes"]],
        "assignees": [assignee["login"] for assignee in node["assignees"]["nodes"]],
        "type": (node.get("issueType") or {}).get("name", ""), "kind": kind_of(node),
        "parent": node.get("parent"),
        "blocked_by": [{"number": b["number"], "state": b["state"].lower()} for b in node["blockedBy"]["nodes"]],
        "fields": fields,
        "open_children": (lambda s: s["total"] - s["completed"])(node.get("subIssuesSummary") or {"total": 0, "completed": 0}),
        "project_items": [{"id": p["id"], "project": p["project"]["number"],
                           "status": (p.get("fieldValueByName") or {}).get("name", "")}
                          for p in (node.get("projectItems") or {}).get("nodes", [])],
    }
    issue["state_comment"] = state_comment(repo, issue, marker, read_every, single_read)
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
        print(json.dumps(raw(repo, node, marker, read_every=True, single_read=True)))
        return
    states = "OPEN" if sys.argv[4] == "open" else None
    what = "open issues" if states else "issues"
    limit, after, seen = int(sys.argv[5]), None, 0
    while True:
        issues = issue_page(owner, name, states, PAGE_SIZE, after)
        if not issues:
            sys.exit(1)
        kept = [node for node in issues["nodes"] if matches(node, SCOPE_RULES) and matches(node, PICK_RULES)]
        for node in kept[:limit - seen]:
            issue = raw(repo, node, marker, read_every=READ_EVERY_STATE, single_read=False)
            if issue is not None:
                print(json.dumps(issue))
        seen += len(kept)
        if past_limit(seen, limit, issues["pageInfo"]["hasNextPage"]):
            break
        if not issues["pageInfo"]["hasNextPage"]:
            return
        after = issues["pageInfo"]["endCursor"]
    sys.stderr.write("flow: stopped at github.limit %d %s; raise it in .flow/config.yaml\n" % (limit, what))
    if os.environ.get("FLOW_LIST_WHOLE"):
        sys.exit(1)


main()

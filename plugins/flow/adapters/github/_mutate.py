"""Writes to the GitHub features labels cannot hold. See _gh.sh.

  _mutate.py field <repo> <number> <field> <option>   set a single-select issue field
  _mutate.py type <repo> <number> <type>              set the issue type
  _mutate.py sync <repo> <project>                    stdin: adapter items, one per line

sync moves each open item's card in the project to the Status its flow state implies: an open
gate is the gate status (the merge gate is the review status), a started step is the running
status, an unstarted item with no missing field and no open blocker is the ready status, any
other is the backlog status. Closed items are left to the project's own workflows. The status
names come from GH_STATUS_<KEY>; an item already at its status costs no write."""
import json, os, subprocess, sys

STATUS = {key: os.environ.get("GH_STATUS_" + key.upper(), default) for key, default in (
    ("backlog", "Backlog"), ("ready", "Ready"), ("gate", "Needs you"), ("running", "In progress"), ("review", "In review"))}


def graphql(query, **variables):
    args = ["gh", "api", "graphql", "-f", "query=" + query]
    for key, value in variables.items():
        args += ["-F" if isinstance(value, int) else "-f", "%s=%s" % (key, value)]
    out = subprocess.run(args, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit("flow: " + (out.stderr.strip() or "graphql call failed"))
    return json.loads(out.stdout)["data"]


def issue_id(owner, name, number):
    q = "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){id}}}"
    return graphql(q, owner=owner, name=name, number=number)["repository"]["issue"]["id"]


def set_field(owner, name, number, field, option):
    q = """query($owner:String!,$name:String!){repository(owner:$owner,name:$name){issueFields(first:50){nodes{
      ... on IssueFieldSingleSelect{id name options{id name}}}}}}"""
    found = [f for f in graphql(q, owner=owner, name=name)["repository"]["issueFields"]["nodes"] if f.get("name") == field]
    if not found:
        sys.exit("flow: no single-select issue field named %s" % field)
    options = [o["id"] for o in found[0]["options"] if o["name"] == option]
    if not options:
        sys.exit("flow: the %s field has no option %s" % (field, option))
    m = "mutation($i:ID!,$f:ID!,$o:ID!){setIssueFieldValue(input:{issueId:$i,issueFields:[{fieldId:$f,singleSelectOptionId:$o}]}){clientMutationId}}"
    graphql(m, i=issue_id(owner, name, number), f=found[0]["id"], o=options[0])


def set_type(owner, name, number, type_name):
    q = "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){issueTypes(first:50){nodes{id name}}}}"
    types = [t["id"] for t in graphql(q, owner=owner, name=name)["repository"]["issueTypes"]["nodes"] if t["name"] == type_name]
    if not types:
        sys.exit("flow: no issue type named %s" % type_name)
    m = "mutation($i:ID!,$t:ID!){updateIssueIssueType(input:{issueId:$i,issueTypeId:$t}){clientMutationId}}"
    graphql(m, i=issue_id(owner, name, number), t=types[0])


def desired(item):
    state = item.get("state", {})
    gate, step = state.get("gate") or "none", state.get("step") or ""
    if gate == "merge" or step == "done":
        return STATUS["review"]
    if gate != "none":
        return STATUS["gate"]
    if step:
        return STATUS["running"]
    if not item.get("needs") and not item.get("open_blockers"):
        return STATUS["ready"]
    return STATUS["backlog"]


def sync(owner, name, project):
    q = """query($owner:String!,$number:Int!){repositoryOwner(login:$owner){... on ProjectV2Owner{projectV2(number:$number){
      id field(name:"Status"){... on ProjectV2SingleSelectField{id options{id name}}}}}}}"""
    board = (graphql(q, owner=owner, number=project).get("repositoryOwner") or {}).get("projectV2")
    if not board:
        sys.exit("flow: %s has no project %d; check github.project" % (owner, project))
    if not board.get("field"):
        sys.exit("flow: project %d has no single-select Status field" % project)
    options = {o["name"]: o["id"] for o in board["field"]["options"]}
    for line in sys.stdin:
        if not line.strip():
            continue
        item = json.loads(line)
        if item.get("status") != "open":
            continue
        want = desired(item)
        current = item.get("project") or {}
        if current.get("status") == want:
            continue
        if want not in options:
            print("flow: the project has no Status %s; %s left as is" % (want, item["id"]), file=sys.stderr)
            continue
        card = current.get("item")
        if not card:
            m = "mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}"
            card = graphql(m, p=board["id"], c=issue_id(owner, name, int(item["id"][3:])))["addProjectV2ItemById"]["item"]["id"]
        m = """mutation($p:ID!,$i:ID!,$f:ID!,$o:String!){updateProjectV2ItemFieldValue(input:{projectId:$p,itemId:$i,fieldId:$f,
          value:{singleSelectOptionId:$o}}){clientMutationId}}"""
        graphql(m, p=board["id"], i=card, f=board["field"]["id"], o=options[want])
        print("%s %s" % (item["id"], want))


def main():
    command, repo = sys.argv[1], sys.argv[2]
    owner, name = repo.split("/", 1)
    if command == "field":
        set_field(owner, name, int(sys.argv[3]), sys.argv[4], sys.argv[5])
    elif command == "type":
        set_type(owner, name, int(sys.argv[3]), sys.argv[4])
    elif command == "sync":
        sync(owner, name, int(sys.argv[3]))
    else:
        sys.exit("flow: unknown command %s" % command)


main()

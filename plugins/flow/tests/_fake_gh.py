"""The fake gh used by the adapter tests. See fake-gh.sh."""
import json, re, sys
db = sys.argv[1]; args = sys.argv[2:]
data = json.load(open(db))
def save(): json.dump(data, open(db, "w"))
def pr():
    return data.setdefault("pr", {"number": 90, "state": "OPEN", "isDraft": True, "mergedAt": None, "url": "https://gh/pull/90", "headRefName": "flow/gh-11", "baseRefName": "main"})
def issue(n): return next(i for i in data["issues"] if i["number"] == int(n))
def pick(i, fields):
    out = {}
    for f in fields:
        if f == "labels": out["labels"] = [{"name": l} for l in i["labels"]]
        elif f == "state": out["state"] = i["state"]
        else: out[f] = i.get(f, "")
    return out
if args[:2] == ["repo", "view"]:
    print(json.dumps({"nameWithOwner": "acme/widgets", "defaultBranchRef": {"name": "main"}})) if "-q" not in args else print("acme/widgets")
elif args[:2] == ["issue", "list"]:
    state = args[args.index("--state") + 1]
    fields = args[args.index("--json") + 1].split(",")
    print(json.dumps([pick(i, fields) for i in data["issues"] if state == "all" or i["state"].lower() == state]))
elif args[:2] == ["issue", "view"]:
    i = issue(args[2]); fields = args[args.index("--json") + 1].split(",")
    if "-q" in args:
        q = args[args.index("-q") + 1]
        print("\n".join(i["labels"]) if "labels" in q else i.get("node", "I_%d" % i["number"]))
    else: print(json.dumps(pick(i, fields)))
elif args[:2] == ["issue", "create"]:
    n = max(i["number"] for i in data["issues"]) + 1
    body = sys.stdin.read() if "--body-file" in args else args[args.index("--body") + 1] if "--body" in args else ""
    labels = args[args.index("--label") + 1].split(",") if "--label" in args else []
    data["issues"].append({"number": n, "title": args[args.index("--title") + 1], "body": body, "state": "OPEN",
                           "labels": labels, "url": "https://gh/%d" % n, "blocked_by": [], "id": 1000 + n, "node": "I_%d" % n})
    save(); print("https://gh/%d" % n)
elif args[:2] == ["issue", "edit"]:
    i = issue(args[2]); k = 3
    while k < len(args):
        if args[k] == "--add-label": i["labels"].append(args[k + 1]); k += 2
        elif args[k] == "--remove-label": i["labels"] = [l for l in i["labels"] if l != args[k + 1]]; k += 2
        else: k += 1
    save()
elif args[:2] == ["issue", "comment"]:
    i = issue(args[2]); i.setdefault("comments", []).append({"id": len(i.get("comments", [])) + 1, "body": sys.stdin.read()}); save()
elif args[:2] == ["issue", "close"]:
    issue(args[2])["state"] = "CLOSED"; save()
elif args[:2] == ["label", "create"]:
    data.setdefault("labels", []).append(args[2]); save()
elif args[:2] == ["pr", "view"]:
    print(json.dumps(pr()))
elif args[:2] == ["pr", "ready"]:
    pr()["isDraft"] = False; save()
elif args[0] == "api" and "graphql" in args:
    q = args[args.index("query=" + [a for a in args if a.startswith("query=")][0][6:]) ] if False else [a for a in args if a.startswith("query=")][0]
    if "addSubIssue" in q:
        p_node = args[args.index("p=") + 1] if "p=" in args else [a for a in args if a.startswith("p=")][0][2:]
        c_node = [a for a in args if a.startswith("c=")][0][2:]
        for i in data["issues"]:
            if i.get("node", "I_%d" % i["number"]) == c_node:
                i["parent"] = int(p_node.split("_")[1])
        save(); print('{"data":{}}')
    elif "parent { number }" in q:
        m = re.search(r"issue\(number:(\d+)\)", q); i = issue(m.group(1))
        print(json.dumps({"data": {"repository": {"issue": {"parent": {"number": i["parent"]} if i.get("parent") else None}}}}) if "-q" not in args
              else print(json.dumps({"number": i["parent"]}) if i.get("parent") else "null"))
    elif "reviewThreads" in q:
        print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": data.get("threads", [])}}}}}))
    elif "resolveReviewThread" in q:
        t = [a for a in args if a.startswith("t=")][0][2:]
        for th in data.get("threads", []):
            if th["id"] == t: th["isResolved"] = True
        save(); print('{"data":{}}')
    else:
        print("fake gh: unknown graphql", file=sys.stderr); sys.exit(1)
elif args[0] == "api":
    rest = args[1:]
    for flag in ("-X", "--method"):
        if flag in rest:
            k = rest.index(flag); rest = rest[:k] + rest[k + 2:]
    path = [a for a in rest if not a.startswith("-")][0]
    m = re.match(r"repos/[^/]+/[^/]+/issues/(\d+)/dependencies/blocked_by", path)
    if m:
        if "--method" in args and args[args.index("--method") + 1] == "POST":
            bid = int([a for a in args if a.startswith("issue_id=")][0].split("=")[1])
            issue(m.group(1)).setdefault("blocked_by", []).append(next(i["number"] for i in data["issues"] if i.get("id") == bid))
            save(); print("{}"); sys.exit()
        print(json.dumps([{"number": b, "state": issue(b)["state"].lower()} for b in issue(m.group(1)).get("blocked_by", [])])); sys.exit()
    m = re.match(r"repos/[^/]+/[^/]+/issues/(\d+)$", path)
    if m and "--jq" in args:
        print(issue(m.group(1)).get("id", 1000 + int(m.group(1)))); sys.exit()
    m = re.match(r"repos/[^/]+/[^/]+/pulls/\d+/comments/(\d+)/replies", path)
    if m:
        for th in data.get("threads", []):
            if th["comments"]["nodes"][0]["databaseId"] == int(m.group(1)):
                th["comments"]["nodes"].append({"databaseId": 9000, "body": sys.stdin.read(), "author": {"login": "bot"}, "createdAt": "t"})
        save(); print("{}"); sys.exit()
    m = re.match(r"repos/[^/]+/[^/]+/issues/(\d+)/comments", path)
    if m and "-X" not in args:
        i = issue(m.group(1))
        if "-F" in args:
            i.setdefault("comments", []).append({"id": len(i.get("comments", [])) + 1, "body": sys.stdin.read()}); save(); print("{}")
        else:
            print(json.dumps(i.get("comments", [])))
        sys.exit()
    m = re.match(r"repos/[^/]+/[^/]+/issues/comments/(\d+)", path)
    if m:
        for i in data["issues"]:
            for c in i.get("comments", []):
                if c["id"] == int(m.group(1)): c["body"] = sys.stdin.read()
        save(); print("{}"); sys.exit()
    print("fake gh: unknown api " + path, file=sys.stderr); sys.exit(1)
else:
    print("fake gh: unknown call " + " ".join(args), file=sys.stderr); sys.exit(1)

"""Per-issue blockers and state comment for the GitHub list operation. See list.sh."""
import json, re, subprocess, sys
repo, kind, marker = sys.argv[1], sys.argv[2], sys.argv[3]
def gh(*args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True)
    return json.loads(out.stdout) if out.returncode == 0 and out.stdout.strip() else []
for issue in json.load(sys.stdin):
    n = issue["number"]
    issue["blocked_by"] = gh("api", "repos/%s/issues/%d/dependencies/blocked_by" % (repo, n))
    issue["state_comment"] = {}
    if any(l["name"].split(":")[0] in ("step", "gate", "wt", "flow") for l in issue["labels"]):
        for c in gh("api", "repos/%s/issues/%d/comments?per_page=100" % (repo, n)):
            if marker in c.get("body", ""):
                m = re.search(r"```json\n(.*?)\n```", c["body"], re.S)
                try:
                    issue["state_comment"] = json.loads(m.group(1)) if m else {}
                except ValueError:
                    pass
                break
    print(json.dumps(issue))

"""Ready filter for the adapters. See filter-ready.sh."""
import json, os, subprocess, sys
plugin = sys.argv[1]
items = json.load(sys.stdin)
known = {i["id"]: i.get("status", "open") for i in items}
cache = {}

def adapter_for(item_id):
    if item_id.startswith("gh#"): return "github"
    if item_id.startswith("local:"): return "local"
    return None

def blocker_open(item_id):
    if item_id in known:
        return known[item_id] == "open"
    if item_id in cache:
        return cache[item_id]
    name = adapter_for(item_id)
    status = "open"
    if name:
        try:
            out = subprocess.run([os.path.join(plugin, "adapters", name, "read.sh"), item_id],
                                 capture_output=True, text=True, timeout=60)
            if out.returncode == 0 and out.stdout.strip():
                status = json.loads(out.stdout).get("status", "open")
            else:
                status = "unknown"
        except Exception:
            status = "unknown"
    cache[item_id] = status != "closed"
    return cache[item_id]

ready = []
for item in items:
    if item.get("status", "open") != "open":
        continue
    if item.get("state", {}).get("gate", "none") not in ("", "none"):
        continue
    if any(blocker_open(b) for b in item.get("blocked_by", [])):
        continue
    ready.append(item)
print(json.dumps(ready))

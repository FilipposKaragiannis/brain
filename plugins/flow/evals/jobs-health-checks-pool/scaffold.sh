#!/bin/sh
# Fixture: the flow fixture with wt-1 claimed for the item and a run record two days old whose
# process is gone. The worktree is clean and has no commit past main, so it is an empty claim.
# The record names a pid no process has, so the health check finds a dead run whatever runs here.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
python3 - <<'PY'
import json, os, time
stamp = lambda: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 172800))
for path, key in ((".flow/runs/local-task-1.json", "started"), (".pool/wt-1/.flow/claim.json", "claimed_at")):
    record = json.load(open(path))
    record[key] = stamp()
    if key == "started":
        record["pid"] = 999999
    json.dump(record, open(path, "w"))
two_days_ago = time.time() - 172800
for root, _, files in os.walk(".pool/wt-1/.flow/reports"):
    for path in [root] + [os.path.join(root, f) for f in files]:
        os.utime(path, (two_days_ago, two_days_ago))
PY

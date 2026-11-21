#!/bin/sh
# Fixture: the flow fixture with wt-1 claimed for the item and a run record two days old whose
# process is gone. The worktree is clean and has no commit past main, so it is an empty claim.
# The record names a pid no process has, so the health check finds a dead run whatever runs here.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" implement
two_days_in_seconds=172800; pid_of_no_process=999999
two_days_ago="$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - int(sys.argv[1]))))' "$two_days_in_seconds")"
dead_run="$("$P/scripts/state.sh" list runs local:task/1 | python3 -c 'import json, sys
run = json.load(sys.stdin); run["started"] = sys.argv[1]; run["pid"] = int(sys.argv[2]); print(json.dumps(run))' "$two_days_ago" "$pid_of_no_process")"
"$P/scripts/state.sh" set local:task/1 "run:=$dead_run"
python3 - "$two_days_ago" "$two_days_in_seconds" <<'PY'
import json, os, sys, time
claimed_at, seconds_back = sys.argv[1], int(sys.argv[2])
claim_path = ".pool/wt-1/.flow/claim.json"
claim = json.load(open(claim_path))
claim["claimed_at"] = claimed_at
json.dump(claim, open(claim_path, "w"))
two_days_back = time.time() - seconds_back
for root, _, files in os.walk(".pool/wt-1/.flow/reports"):
    for path in [root] + [os.path.join(root, f) for f in files]:
        os.utime(path, (two_days_back, two_days_back))
PY

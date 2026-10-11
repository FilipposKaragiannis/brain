#!/bin/sh
# A fake gh for the adapter tests. State lives in $FAKE_GH_DIR: issues.json and a call log.
# Covers the calls the GitHub adapter makes and nothing else.
log="$FAKE_GH_DIR/calls.log"; db="$FAKE_GH_DIR/issues.json"
printf '%s\n' "$*" >> "$log"
python3 -I "$FAKE_GH_DIR/_fake_gh.py" "$db" "$@"

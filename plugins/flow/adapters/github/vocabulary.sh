#!/bin/sh
# github vocabulary: the names a new item may use, as JSON: {"types": [...], "areas": [...]}.
# Types when github.types is true; areas are the options of the github.fields.area issue field.
. "$(dirname "$0")/_gh.sh"
python3 -I "$FLOW_PLUGIN/adapters/github/_mutate.py" vocabulary "$(gh_repo)" "$(cfg github.fields.area)" "$(cfg github.types)"

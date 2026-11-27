#!/bin/sh
# pr-report.sh <reports>: the Verification section of a pull request body, as Markdown on stdout,
# from <reports>/verify.json (scripts/_pr_report.py): the `## Verification` heading, the verdict
# line, the count line, the proofs table, the Not checked list, an **Evidence** reference to each
# image and video under <reports>/evidence/, each alone in its paragraph, and a collapsed excerpt
# of each text file there. scripts/pr-publish.sh swaps it whole into the body and attaches the
# images and videos, so gh turns each reference into its asset URL. No model runs.
# Exit 0 with the section; 1 when <reports> holds no readable verify.json object or the report
# lacks a key the section needs, the reason on stderr; 2 on a usage error.
set -u
. "$(dirname "$0")/../lib/flow.sh"
USAGE="usage: pr-report.sh <reports>"
[ $# -eq 1 ] || die "$USAGE" 2
cached_python3 -I "$FLOW_PLUGIN/scripts/_pr_report.py" "$1"

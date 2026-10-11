#!/bin/sh
# lesson.sh <kind> <item> <text> [--rule ID] [--step STEP]: append one lesson to
# <flow home>/lessons.jsonl. Kinds: escalation, review-blocker, correction, other. The retro
# reads this file and routes each lesson to a durable home.
. "$(dirname "$0")/../lib/flow.sh"
[ $# -ge 3 ] || die "usage: lesson.sh <kind> <item> <text> [--rule ID] [--step STEP]" 2
kind="$1"; item="$2"; text="$3"; shift 3
rule=""; step=""
while [ $# -gt 0 ]; do case "$1" in --rule) rule="$2"; shift 2 ;; --step) step="$2"; shift 2 ;; *) die "unknown option $1" 2 ;; esac; done
home="$(flow_home)"; mkdir -p "$home"
json_obj "time=$(now_iso)" "kind=$kind" "item=$item" "step=$step" "rule=$rule" "text=$text" "host=$(host_name)" >> "$home/lessons.jsonl"
echo >> "$home/lessons.jsonl"
echo "lesson recorded in $home/lessons.jsonl"

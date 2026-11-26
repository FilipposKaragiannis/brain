#!/bin/sh
# feel-test-gate.sh: the feel-test gate a passing verify raises on rendered code sends the owner to
# the verify report for the verdict, the proofs and the Not checked list, and names no check table.
# An item on the local adapter in a throwaway repo goes through its steps to a verify result that
# asks for a feel test, and the checks read the message of the gate record advance.sh writes.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
# shellcheck disable=SC2154 # _flow_setup.sh, sourced below, sets fails and its check helpers count into it
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"

feel_item="$("$P/adapters/local/create.sh" task "Rendered change" --size S)"
reports="$("$P/scripts/next.sh" "$feel_item" --json | jget reports)"
for step in implement test review; do
  printf '{"status":"done","summary":"%s done"}\n' "$step" > "$reports/$step.json"
  "$P/scripts/advance.sh" "$feel_item" >/dev/null
  "$P/scripts/next.sh" "$feel_item" >/dev/null
done
printf '{"status":"pass","attempts":1,"feel_test":true,"checks":[{"name":"tests","status":"pass","summary":"ok"}]}\n' > "$reports/verify.json"
"$P/scripts/advance.sh" "$feel_item" >/dev/null 2>&1
gate_message="$(jget message < ".flow/gates/$(item_slug "$feel_item").json")"

echo "feel-test gate"
message_names() { printf '%s\n' "$gate_message" | grep -qF -- "$1"; }
check "FeelTestGate_Message_NamesTheVerdict because the owner reads whether the run passed before signing off" \
  message_names verdict
check "FeelTestGate_Message_NamesTheProofs because the owner reads how each acceptance line was checked before signing off" \
  message_names proofs
check "FeelTestGate_Message_NamesTheNotCheckedList because the owner reads what no check covered before signing off" \
  message_names "Not checked list"
check "FeelTestGate_Message_PointsAtTheVerifyReport because the report holds those parts and what to launch" \
  message_names "\`$reports/verify.md\`"
message_names_no_check_table() { [ -n "$gate_message" ] && ! printf '%s\n' "$gate_message" | grep -qiE 'checks? table'; }
check "FeelTestGate_Message_NamesNoCheckTable because the check table left the report the gate points at" \
  message_names_no_check_table

[ "$fails" -eq 0 ] && { echo "feel-test-gate: ok"; exit 0; }
echo "feel-test-gate: $fails failed"; exit 1

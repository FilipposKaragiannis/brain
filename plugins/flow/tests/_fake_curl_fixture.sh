# _fake_curl_fixture.sh: a curl in $work/fakebin that only appends its arguments to $work/curl.log, for the
# Slack webhook checks. Takes $work. Sourced after _flow_setup.sh, never run.
mkdir -p "$work/fakebin" && printf '#!/bin/sh\necho "$@" >> "%s/curl.log"\n' "$work" > "$work/fakebin/curl" && chmod +x "$work/fakebin/curl"

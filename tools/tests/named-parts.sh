#!/bin/sh
# Tests that tools/test.sh fails the console part named on the command line when a tool its shell
# suite needs is missing, and runs that suite once every tool is there. The suite is a stub in a
# copy of the checkout; node, curl and zsh are stubs on a PATH of their own. Exit 1 on any failure.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

copy="$work/checkout"
mkdir -p "$copy/tools" "$copy/plugins/console/tests" "$copy/plugins/console/app/node_modules"
cp "$root/tools/test.sh" "$copy/tools/"
printf '#!/bin/sh\necho "console suite ran"\n' > "$copy/plugins/console/tests/run.sh"
chmod +x "$copy/plugins/console/tests/run.sh"
tools_with() {
  tools_folder="$work/tools-$1"; rm -rf "$tools_folder"; mkdir "$tools_folder"
  for tool in dirname env; do ln -s "$(command -v "$tool")" "$tools_folder/$tool"; done
  printf '#!/bin/sh\necho %s\n' "$1" > "$tools_folder/node"; chmod +x "$tools_folder/node"
  shift
  for tool in "$@"; do printf '#!/bin/sh\n' > "$tools_folder/$tool"; chmod +x "$tools_folder/$tool"; done
}
console_part() { PATH="$tools_folder" "$copy/tools/test.sh" console > "$work/output" 2>&1 && echo pass || echo fail; }
expect() { [ "$2" = "$3" ] || { echo "FAIL $1"; cat "$work/output"; exit 1; }; echo "ok $1"; }

tools_with 24 curl
expect 'NamedConsoleWithoutZsh_Fails because the zsh pane checks would be skipped' "$(console_part)" fail
expect 'NamedConsoleWithoutZsh_NamesZsh because the owner must see what to install' "$(grep -c 'console cannot run, zsh missing' "$work/output")" 1
expect 'NamedConsoleWithoutZsh_RunsNoSuite because a part that cannot run in full is no pass' "$(grep -c 'console suite ran' "$work/output")" 0
tools_with 24 zsh
expect 'NamedConsoleWithoutCurl_Fails because the real daemon checks would be skipped' "$(console_part)" fail
expect 'NamedConsoleWithoutCurl_NamesCurl because the owner must see what to install' "$(grep -c 'console cannot run, curl missing' "$work/output")" 1
tools_with 22 curl zsh
expect 'NamedConsoleUnderAnOlderNode_Fails because the suite skips every check below Node 24' "$(console_part)" fail
expect 'NamedConsoleUnderAnOlderNode_NamesTheNodeItNeeds because the owner must see what to install' "$(grep -c 'console cannot run, node 24 or newer missing' "$work/output")" 1
rm -r "$copy/plugins/console/app/node_modules"
tools_with 24 curl zsh
expect 'NamedConsoleWithoutAppDependencies_Fails because the real daemon checks would be skipped' "$(console_part)" fail
expect 'NamedConsoleWithoutAppDependencies_GivesTheInstallCommand because the owner must see what to run' "$(grep -c 'cd plugins/console/app && npm ci' "$work/output")" 1
mkdir "$copy/plugins/console/app/node_modules"
expect 'NamedConsoleWithEveryTool_Passes because nothing it needs is missing' "$(console_part)" pass
expect 'NamedConsoleWithEveryTool_RunsTheSuite because the part is the suite' "$(grep -c 'console suite ran' "$work/output")" 1

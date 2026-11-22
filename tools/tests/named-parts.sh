#!/bin/sh
# Tests that a console part named on the test script's command line fails when a tool it needs is
# missing.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

copy="$work/checkout"
mkdir -p "$copy/tools" "$copy/plugins/console/tests" "$copy/plugins/console/app/node_modules"
cp "$root/tools/test.sh" "$copy/tools/"
printf '#!/bin/sh\n' > "$copy/plugins/console/tests/run.sh"
chmod +x "$copy/plugins/console/tests/run.sh"
supported_node=24
older_node=$((supported_node - 1))
tools_with() {
  tools_folder="$work/tools-$1"; rm -rf "$tools_folder"; mkdir "$tools_folder"
  for tool in dirname env; do ln -s "$(command -v "$tool")" "$tools_folder/$tool"; done
  printf '#!/bin/sh\necho %s\n' "$1" > "$tools_folder/node"; chmod +x "$tools_folder/node"
  shift
  for tool in "$@"; do printf '#!/bin/sh\n' > "$tools_folder/$tool"; chmod +x "$tools_folder/$tool"; done
}
console_part() { PATH="$tools_folder" "$copy/tools/test.sh" console > "$work/output" 2>&1 && echo pass || echo fail; }
expect() { [ "$2" = "$3" ] || { echo "FAIL $1"; cat "$work/output"; exit 1; }; echo "ok $1"; }

tools_with "$supported_node" curl
expect 'NamedConsoleWithoutZsh_Fails because the zsh pane checks would be skipped' "$(console_part)" fail
expect 'NamedConsoleWithoutZsh_NamesZsh because the owner must see what to install' "$(grep -c zsh "$work/output")" 1
tools_with "$supported_node" zsh
expect 'NamedConsoleWithoutCurl_Fails because the real daemon checks would be skipped' "$(console_part)" fail
expect 'NamedConsoleWithoutCurl_NamesCurl because the owner must see what to install' "$(grep -c curl "$work/output")" 1
tools_with "$older_node" curl zsh
expect 'NamedConsoleUnderAnOlderNode_Fails because the suite skips every check below Node 24' "$(console_part)" fail
expect 'NamedConsoleUnderAnOlderNode_NamesTheNodeItNeeds because the owner must see what to install' "$(grep -c "node $supported_node" "$work/output")" 1
rm -r "$copy/plugins/console/app/node_modules"
tools_with "$supported_node" curl zsh
expect 'NamedConsoleWithoutAppDependencies_Fails because the real daemon checks would be skipped' "$(console_part)" fail
expect 'NamedConsoleWithoutAppDependencies_GivesTheInstallCommand because the owner must see what to run' "$(grep -c 'cd plugins/console/app && npm ci' "$work/output")" 1
mkdir "$copy/plugins/console/app/node_modules"
expect 'NamedConsoleWithEveryTool_Passes because nothing it needs is missing' "$(console_part)" pass
printf '#!/bin/sh\nexit 1\n' > "$copy/plugins/console/tests/run.sh"
expect 'NamedConsoleWhoseSuiteFails_Fails because the part is the suite' "$(console_part)" fail
plugins_part() { PATH="$tools_folder" "$copy/tools/test.sh" plugins > "$work/output" 2>&1 && echo pass || echo fail; }
expect 'NamedPluginsWithoutTheClaudeCommand_Fails because no plugin would be validated' "$(plugins_part)" fail
expect 'NamedPluginsWithoutTheClaudeCommand_GivesTheInstallCommand because the owner must see what to run' "$(grep -c 'npm install -g @anthropic-ai/claude-code' "$work/output")" 1
console_app_part() { PATH="$tools_folder" "$copy/tools/test.sh" console-app > "$work/output" 2>&1 && echo pass || echo fail; }
expect 'NamedConsoleAppWithoutTheInterfaceDependencies_Fails because the interface checks would not run' "$(console_app_part)" fail
expect 'NamedConsoleAppWithoutTheInterfaceDependencies_NamesTheirFolder because the owner must see what to install' "$(grep -c 'plugins/console/app/ui/node_modules' "$work/output")" 1

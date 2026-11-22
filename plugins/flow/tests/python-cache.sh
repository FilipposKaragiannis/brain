#!/bin/sh
# python-cache.sh: the compiled-code cache flow's python starts keep, on the local adapter in a
# throwaway repo. The board reads the same with a cold cache, a warm one, a cache folder python
# cannot write, one holding files that are not compiled code and a file in the folder's place; the
# cache folder is made owner-only under XDG_CACHE_HOME when that is an absolute path, else under
# ~/.cache, and only when python starts; flow's own helper modules are compiled there, never beside
# flow's sources; a sandboxed suite caches under its own work folder, whatever XDG_CACHE_HOME its
# runner had.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

cache_folder="$HOME/.cache/flow/python"
board() { "$plugin/scripts/board.sh" 2>&1; }
helpers_compiled_in() { find "$1$plugin" "$1$(cd "$plugin" && pwd -P)" -name '*.pyc' 2>/dev/null | grep -q .; }
owner_only() { find "$1" -prune -type d -perm 700 | grep -q .; }

echo "python cache: one board, whatever state the cache is in"
new_repo cache
"$local_adapter/create.sh" task "Parser rewrite" --size M --body x >/dev/null
rm -rf "$cache_folder"
cold="$(board)"
check "ColdCache_ShowsTheBoard: a first start with no cache folder still shows the open item" \
  'printf "%s" "$cold" | grep -q "Parser rewrite"'
check "ColdCache_KeepsFlowsHelpersCompiledInTheUsersCacheFolder: the next start reads flow's helpers compiled instead of compiling them again" \
  'helpers_compiled_in "$cache_folder"'
check "MissingCacheFolder_IsMadeOwnerOnly: no other user can plant compiled code that flow would run" \
  'owner_only "$cache_folder"'
check "WarmCache_ShowsTheSameBoard: a start that reads the cache shows what a cold one showed" \
  '[ "$(board)" = "$cold" ]'
find "$cache_folder" -name '*.pyc' | while read -r compiled; do printf 'not a compiled module' > "$compiled"; done
check "CacheFilesThatAreNotCompiledCode_ShowTheSameBoardWithNoNoise: a cache file python does not recognise is compiled again, quietly" \
  '[ "$(board)" = "$cold" ]'
rm -rf "$cache_folder" && mkdir -p "$cache_folder" && chmod 500 "$cache_folder"
check "UnwritableCacheFolder_ShowsTheSameBoardWithNoNoise: a cache folder python cannot write only costs time" \
  '[ "$(board)" = "$cold" ]'
chmod 700 "$cache_folder" && rm -rf "$cache_folder" && printf 'a file\n' > "$cache_folder"
check "FileInTheCacheFoldersPlace_ShowsTheSameBoardWithNoNoise: a cache folder that cannot be made only costs time" \
  '[ "$(board)" = "$cold" ]'
rm -f "$cache_folder"

echo "python cache: where it lives"
chosen_cache_home="$work/chosen-cache-home"
XDG_CACHE_HOME="$chosen_cache_home" board >/dev/null
check "AbsoluteCacheHomeVariable_HoldsTheCache: the cache home the user chose is used" \
  'helpers_compiled_in "$chosen_cache_home/flow/python"'
check "AbsoluteCacheHomeVariable_CacheFolderIsOwnerOnly: no other user can plant compiled code in the cache home the user chose" \
  'owner_only "$chosen_cache_home/flow/python"'
rm -rf "$cache_folder"
check "RelativeCacheHomeVariable_UsesTheHomeCache: a relative cache home would land in the working folder, so ~/.cache is used" \
  'XDG_CACHE_HOME=relative-cache board >/dev/null && helpers_compiled_in "$cache_folder" && [ ! -e relative-cache ]'
cache_home_of_a_sourcing_shell="$work/cache-home-of-a-sourcing-shell"; mkdir -p "$cache_home_of_a_sourcing_shell"
check "SourcingFlowWithoutStartingPython_WritesNoCacheFolder: a shell that only loads flow's helpers leaves the cache home as it was" \
  'XDG_CACHE_HOME="$cache_home_of_a_sourcing_shell" sh -c ". \"\$FLOW_PLUGIN/lib/flow.sh\"" && [ -z "$(ls -A "$cache_home_of_a_sourcing_shell")" ]'

cp -R "$plugin" "$work/flow-copy"
find "$work/flow-copy" \( -name __pycache__ -o -name '*.pyc' \) -prune -exec rm -rf {} +
check "BoardFromACopyOfFlow_LeavesNoCompiledFileBesideFlowsSources: flow's folders hold sources only, whatever python would do by itself" \
  'FLOW_PLUGIN="$work/flow-copy" "$work/flow-copy/scripts/board.sh" >/dev/null 2>&1 && ! find "$work/flow-copy" \( -name "*.pyc" -o -name __pycache__ \) | grep -q .'

echo "python cache: inside the test sandbox"
outside_cache="$work/outside-cache"; mkdir -p "$outside_cache" "$work/nested"
check "SandboxWithAnOutsideCacheHome_KeepsTheCacheUnderItsOwnWorkFolder: a suite never writes to the cache home its runner was started with" \
  '(export XDG_CACHE_HOME="$outside_cache"; . "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work/nested" "$plugin"; "$plugin/scripts/board.sh" >/dev/null 2>&1; helpers_compiled_in "$work/nested/home/.cache/flow/python" && [ -z "$(ls -A "$outside_cache")" ])'

[ "$fails" -eq 0 ] && { echo "python-cache: ok"; exit 0; }
echo "python-cache: $fails failed"; exit 1

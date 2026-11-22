#!/bin/sh
# python-cache.sh: the compiled-code cache flow's python starts keep, on the local adapter in a
# throwaway repo. The board reads the same with a cold cache, a warm one, a cache folder python
# cannot write, one holding garbage and a file in the folder's place; the cache folder is made
# owner-only under XDG_CACHE_HOME when that is an absolute path, else under ~/.cache; flow's own
# helper modules are compiled there, never into the checkout.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

cache_folder="$HOME/.cache/flow/python"
board() { "$plugin/scripts/board.sh" 2>&1; }
compiled_in() { find "$1" -name "$2.*.pyc" 2>/dev/null | grep -q .; }
owner_only() { [ "$(ls -ld "$1" | cut -c1-10)" = drwx------ ]; }
compiled_in_the_checkout() { find "$plugin" -newer "$work/started" \( -name '*.pyc' -o -name __pycache__ \) 2>/dev/null | grep -q .; }

echo "python cache: one board, whatever state the cache is in"
new_repo cache
: > "$work/started"
"$local_adapter/create.sh" task "Parser rewrite" --size M --body x >/dev/null
rm -rf "$cache_folder"
cold="$(board)"
check "ColdCache_ShowsTheBoard: a first start with no cache folder still shows the open item" \
  'printf "%s" "$cold" | grep -q "Parser rewrite"'
check "ColdCache_KeepsFlowsHelperCompiledInTheUsersCacheFolder: the next start reads _process compiled instead of compiling it again" \
  'compiled_in "$cache_folder" _process'
check "MissingCacheFolder_IsMadeOwnerOnly: no other user can plant compiled code that flow would run" \
  'owner_only "$cache_folder"'
check "WarmCache_ShowsTheSameBoard: a start that reads the cache shows what a cold one showed" \
  '[ "$(board)" = "$cold" ]'
find "$cache_folder" -name '*.pyc' | while read -r compiled; do printf 'not a compiled module' > "$compiled"; done
check "GarbageInTheCache_ShowsTheSameBoardWithNoNoise: a cache file that is not compiled code is compiled again, quietly" \
  '[ "$(board)" = "$cold" ]'
rm -rf "$cache_folder" && mkdir -p "$cache_folder" && chmod 500 "$cache_folder"
check "UnwritableCacheFolder_ShowsTheSameBoardWithNoNoise: a cache folder python cannot write only costs time" \
  '[ "$(board)" = "$cold" ]'
chmod 700 "$cache_folder" && rm -rf "$cache_folder" && printf 'a file\n' > "$cache_folder"
check "FileInTheCacheFoldersPlace_ShowsTheSameBoardWithNoNoise: a cache folder that cannot be made only costs time" \
  '[ "$(board)" = "$cold" ]'
rm -f "$cache_folder"

echo "python cache: where it lives"
check "AbsoluteXdgCacheHome_HoldsTheCache: the cache home the user chose is used, owner-only" \
  'XDG_CACHE_HOME="$work/xdg" board >/dev/null && compiled_in "$work/xdg/flow/python" _process && owner_only "$work/xdg/flow/python"'
rm -rf "$cache_folder"
check "RelativeXdgCacheHome_UsesTheHomeCache: a relative cache home would land in the working folder, so ~/.cache is used" \
  'XDG_CACHE_HOME=relative-cache board >/dev/null && compiled_in "$cache_folder" _process && [ ! -e relative-cache ]'
check "AnyCacheState_CompilesNothingIntoTheCheckout: flow's own folders stay as the checkout has them" \
  '! compiled_in_the_checkout'

[ "$fails" -eq 0 ] && { echo "python-cache: ok"; exit 0; }
echo "python-cache: $fails failed"; exit 1

# _init_fixture.sh: a copy of the plugin for init to change, its init and session-start scripts, and a
# fresh repo the shell is left in. Takes $P, $work and $HOME. Sourced after _flow_setup.sh, never
# run.
plugin_copy="$work/plugin"; cp -R "$P" "$plugin_copy"; rm -rf "$plugin_copy/evals/results"
init="$plugin_copy/skills/init/scripts/init.sh"; start="$plugin_copy/hooks/session-start.sh"
mkdir -p "$work/fresh" && cd "$work/fresh" && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
codex_rules="$HOME/.codex/rules/flow.rules"   # this repo has no .codex folder, so the user's

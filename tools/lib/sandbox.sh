# sandbox.sh: sourced by every test suite in this repo, which then calls
# sandbox_enter <work> <watched dir> once it has made its throwaway folder, and
# sandbox_close <status> on exit. A test may write only under <work>; <watched dir> is the folder
# the suite tests, whose files no test may change. A suite may run from a git hook or an agent with
# GIT_DIR exported, or from a shell that points git, Claude, Codex or flow at the owner's own
# config, and every one of those would aim the suite's git and flow calls at a real checkout. So
# all of them are cleared, and the checkout the suite runs from is watched: a run that changes its
# config, adds a worktree into <work> or edits a file under <watched dir> fails, whatever the tests
# said. sandboxed.sh beside it runs one command the same way; tools/lint.sh checks every suite.

sandbox_failure_message="the suite left the checkout it runs from as it found it"

sandbox_enter() { # sandbox_enter <work> <watched dir>
  sandbox_work="$1"; sandbox_watched="$2"
  sandbox_work_real="$(cd "$sandbox_work" && pwd -P)"
  sandbox_repositories="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  # shellcheck disable=SC2046
  unset $(git rev-parse --local-env-vars) GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
    GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM XDG_CONFIG_HOME \
    CLAUDE_CONFIG_DIR CODEX_HOME FLOW_HOME FLOW_SLACK_WEBHOOK FLOW_LAUNCH_AGENTS \
    FLOW_MAIN_WORKTREE FLOW_MAIN_WORKTREE_FOLDER FLOW_MAIN_WORKTREE_SEARCH_PATH FLOW_GIT_PROGRAM
  sandbox_repositories="$(printf '%s\n%s\n' "$sandbox_repositories" \
    "$(git -C "$sandbox_watched" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" | sort -u | sed '/^$/d')"
  sandbox_inside_checkout && { echo "sandbox: $sandbox_work is inside a real checkout; set TMPDIR elsewhere" >&2; exit 2; }
  mkdir -p "$sandbox_work/home"
  HOME="$sandbox_work/home"; GIT_CONFIG_NOSYSTEM=1; PYTHONDONTWRITEBYTECODE=1
  GIT_CEILING_DIRECTORIES="$(cd "$sandbox_work_real/.." && pwd -P)"
  export HOME GIT_CONFIG_NOSYSTEM PYTHONDONTWRITEBYTECODE GIT_CEILING_DIRECTORIES
  sandbox_before="$(sandbox_print)"
}

sandbox_inside_checkout() {
  printf '%s\n' "$sandbox_repositories" | {
    while read -r sandbox_repository; do
      [ -n "$sandbox_repository" ] || continue
      sandbox_top="$(cd "$sandbox_repository/.." && pwd -P)"
      case "$sandbox_work_real/" in "$sandbox_top"/*) exit 0 ;; esac
    done
    exit 1
  }
}

sandbox_print() {
  printf '%s\n' "$sandbox_repositories" | while read -r sandbox_repository; do
    echo "repo $sandbox_repository"
    git config --file "$sandbox_repository/config" --get-regexp '^(core\.(bare|worktree)|user\.)' | sed 's/^/  config /'
    cat "$sandbox_repository"/worktrees/*/gitdir 2>/dev/null | grep -F -e "$sandbox_work" -e "$sandbox_work_real" | sed 's/^/  worktree in the sandbox /'
  done
  env -u GIT_CEILING_DIRECTORIES git -C "$sandbox_watched" --no-optional-locks status --porcelain -- . 2>/dev/null | sed 's/^/  watched file /'
  env -u GIT_CEILING_DIRECTORIES git -C "$sandbox_watched" ls-files -z --modified --others --exclude-standard -- . 2>/dev/null |
    xargs -0 sh -c 'watched="$1"; shift
      for path do
        [ -f "$watched/$path" ] || continue
        echo "  watched content $(git hash-object -- "$watched/$path") $path"
      done' sh "$sandbox_watched"
}

sandbox_close() { # sandbox_close <status>: the exit status, 1 when the run touched a real checkout
  sandbox_status="$1"
  sandbox_after="$(sandbox_print)"
  if [ "$sandbox_after" != "$sandbox_before" ]; then
    echo "  FAIL $sandbox_failure_message" >&2
    printf 'before:\n%s\nafter:\n%s\n' "$sandbox_before" "$sandbox_after" | sed 's/^/       /' >&2
    sandbox_status=1
  fi
  rm -rf "$sandbox_work"
  exit "$sandbox_status"
}

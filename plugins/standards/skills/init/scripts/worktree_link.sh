#!/bin/sh
# init.sh, machine scope, sourced after the exclude block. Machine scope tracks no .standards, so a
# linked worktree checks out none: each one gets a link to the main worktree's, and the git hooks,
# the gates and the session hooks find the same config there. A real .standards folder in a linked
# worktree is the owner's and stays. When flow is installed, its worktree_setup gets the line that
# links the worktrees flow adds later. It uses init's note, repair, tmpfile and main_worktree_folder.
shared_standards="$main_worktree_folder/.standards"
flow_config=".flow/config.yaml"
flow_setup_item="  - [ -e .standards ] || ln -s '$shared_standards' .standards"
linked_worktree_folders() {
  git worktree list --porcelain | sed -n 's/^worktree //p' | sed 1d
}
link_standards() {
  worktree_standards="$1"
  rm -f "$worktree_standards" && ln -s "$shared_standards" "$worktree_standards" && note "$worktree_standards -> $shared_standards"
}
link_worktree_standards() {
  worktree_standards="$1/.standards"
  if [ -L "$worktree_standards" ]; then
    [ "$(readlink "$worktree_standards")" = "$shared_standards" ] ||
      repair "$worktree_standards does not link to $shared_standards" link_standards "$worktree_standards"
  elif [ -e "$worktree_standards" ]; then
    echo "init: note: $worktree_standards is a folder of its own, so init leaves it; that worktree reads its own config, not $shared_standards"
  else
    repair "$worktree_standards is missing (wanted a link to $shared_standards)" link_standards "$worktree_standards"
  fi
}
add_flow_setup_item() {
  FLOW_SETUP_ITEM="$flow_setup_item" awk '{ print } $0 == "worktree_setup:" && !item_added { print ENVIRON["FLOW_SETUP_ITEM"]; item_added = 1 }' \
    "$flow_config" > "$(tmpfile flow-config)" || return 0
  cat "$(tmpfile flow-config)" > "$flow_config" && note "$flow_config: worktree_setup links .standards in a new worktree"
}
wire_flow_setup() {
  [ -f "$flow_config" ] || return 0
  case "$main_worktree_folder" in *"'"*|*" #"*)
    echo "init: note: $main_worktree_folder holds a single quote or ' #', so init writes no worktree_setup line that names it; link .standards to $shared_standards in each new worktree yourself"
    return 0 ;;
  esac
  grep -qxF -- "$flow_setup_item" "$flow_config" && return 0
  if grep -qxF 'worktree_setup:' "$flow_config"; then
    repair "$flow_config: worktree_setup lacks the line that links .standards" add_flow_setup_item
    return 0
  fi
  echo "init: note: $flow_config has no plain worktree_setup: line, so init leaves it to you. Add this item under worktree_setup: ${flow_setup_item#  - }"
}

while IFS= read -r linked_worktree_folder; do
  [ -d "$linked_worktree_folder" ] && link_worktree_standards "$linked_worktree_folder"
done <<EOF
$(linked_worktree_folders)
EOF
wire_flow_setup

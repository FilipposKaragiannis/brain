#!/usr/bin/env bash
#
# install-skills.sh — interactively install skills from this repo.
#
# Flow:
#   1. Pick which skills to install (fzf multi-select if available, else numbered toggle).
#   2. Global or local install?
#   3. Symlink or copy?
#   4. If local: install into the current dir or another dir?
#
# Skills land in <target>/.claude/skills/<skill-name>.
#   Global target: $HOME
#   Local target:  chosen directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SRC="$SCRIPT_DIR/skills"

# ---------- styling ----------
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
  CYAN=$'\033[36m'; RED=$'\033[31m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; GREEN=""; YELLOW=""; CYAN=""; RED=""; RESET=""
fi

die() { printf '%s\n' "${RED}error:${RESET} $*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

[ -d "$SKILLS_SRC" ] || die "no skills directory found at $SKILLS_SRC"

# ---------- discover skills ----------
# Populate parallel arrays: SKILL_NAMES (dir name) and SKILL_DESCS (short description).
SKILL_NAMES=()
SKILL_DESCS=()

# Pull the `description:` value out of a SKILL.md, collapsing folded/multiline
# YAML into a single line, and truncate for display.
read_description() {
  awk '
    /^---[[:space:]]*$/ { fence++; next }
    fence == 1 {
      if ($0 ~ /^description:/) { capture=1; sub(/^description:[[:space:]]*/, ""); }
      else if ($0 ~ /^[A-Za-z0-9_-]+:/) { capture=0 }
      if (capture) {
        line=$0
        sub(/^[[:space:]]*>[-+]?[[:space:]]*$/, "", line)  # drop a lone fold indicator
        sub(/^[[:space:]]+/, " ", line)
        gsub(/[[:space:]]+/, " ", line)
        if (line != "" && line != " ") buf = buf line " "
      }
    }
    fence >= 2 { exit }
    END { sub(/^[[:space:]]+/, "", buf); print buf }
  ' "$1"
}

while IFS= read -r skill_md; do
  dir="$(dirname "$skill_md")"
  name="$(basename "$dir")"
  desc="$(read_description "$skill_md")"
  SKILL_NAMES+=("$name")
  SKILL_DESCS+=("$desc")
done < <(find "$SKILLS_SRC" -mindepth 2 -maxdepth 2 -name SKILL.md | sort)

[ "${#SKILL_NAMES[@]}" -gt 0 ] || die "no skills (skills/*/SKILL.md) found under $SKILLS_SRC"

# ---------- selection ----------
SELECTED=()

select_with_fzf() {
  local lines=() i
  for i in "${!SKILL_NAMES[@]}"; do
    lines+=("${SKILL_NAMES[$i]}	${SKILL_DESCS[$i]}")
  done
  local chosen
  chosen="$(printf '%s\n' "${lines[@]}" | fzf --multi \
    --with-nth=1,2 --delimiter='\t' \
    --prompt="skills> " \
    --header="TAB to select multiple, ENTER to confirm, ESC to cancel" \
    --preview="cat $SKILLS_SRC/{1}/SKILL.md" --preview-window=right:60%:wrap || true)"
  [ -n "$chosen" ] || die "nothing selected"
  while IFS=$'\t' read -r name _; do
    [ -n "$name" ] && SELECTED+=("$name")
  done <<< "$chosen"
}

select_with_menu() {
  local n="${#SKILL_NAMES[@]}" i
  local picked=()
  for ((i=0; i<n; i++)); do picked[$i]=0; done

  while true; do
    printf '\n%s\n' "${BOLD}Available skills${RESET} ${DIM}(toggle by number)${RESET}"
    for ((i=0; i<n; i++)); do
      local mark=" "
      [ "${picked[$i]}" -eq 1 ] && mark="${GREEN}x${RESET}"
      printf '  [%b] %2d) %s%s%s  %s%s%s\n' \
        "$mark" "$((i+1))" "$CYAN" "${SKILL_NAMES[$i]}" "$RESET" \
        "$DIM" "${SKILL_DESCS[$i]}" "$RESET"
    done
    printf '\n%s\n' "${DIM}numbers/ranges to toggle (e.g. 1 3 5-7), 'a' all, 'n' none, 'd' done, 'q' quit${RESET}"
    printf '%s' "> "
    local input; IFS= read -r input || input="q"

    case "$input" in
      q|Q) die "cancelled" ;;
      d|D|"")
        for ((i=0; i<n; i++)); do [ "${picked[$i]}" -eq 1 ] && SELECTED+=("${SKILL_NAMES[$i]}"); done
        [ "${#SELECTED[@]}" -gt 0 ] && break
        info "${YELLOW}nothing selected yet${RESET}" ;;
      a|A) for ((i=0; i<n; i++)); do picked[$i]=1; done ;;
      n|N) for ((i=0; i<n; i++)); do picked[$i]=0; done ;;
      *)
        local tok
        for tok in $input; do
          if [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then
            local lo="${tok%-*}" hi="${tok#*-}" j
            for ((j=lo; j<=hi; j++)); do
              [ "$j" -ge 1 ] && [ "$j" -le "$n" ] && picked[$((j-1))]=$((1 - picked[$((j-1))]))
            done
          elif [[ "$tok" =~ ^[0-9]+$ ]]; then
            [ "$tok" -ge 1 ] && [ "$tok" -le "$n" ] && picked[$((tok-1))]=$((1 - picked[$((tok-1))]))
          else
            info "${YELLOW}ignored: $tok${RESET}"
          fi
        done ;;
    esac
  done
}

# ---------- prompt helpers ----------
# ask_choice "Question?" "key1:Label one" "key2:Label two" ... -> echoes chosen key.
# Prompts go to stderr; only the chosen key goes to stdout (this is called via $()).
ask_choice() {
  local question="$1"; shift
  local opts=("$@") i
  while true; do
    printf '\n%s\n' "${BOLD}${question}${RESET}" >&2
    for i in "${!opts[@]}"; do
      printf '  %d) %s\n' "$((i+1))" "${opts[$i]#*:}" >&2
    done
    printf '%s' "> " >&2
    local ans; IFS= read -r ans || die "cancelled"
    if [[ "$ans" =~ ^[0-9]+$ ]] && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then
      printf '%s' "${opts[$((ans-1))]%%:*}"
      return 0
    fi
    printf '%s\n' "${YELLOW}enter a number 1-${#opts[@]}${RESET}" >&2
  done
}

# ---------- run selection ----------
info "${BOLD}Skill installer${RESET} ${DIM}($SKILLS_SRC)${RESET}"
if command -v fzf >/dev/null 2>&1; then
  select_with_fzf
else
  select_with_menu
fi

printf '\n%s\n' "${BOLD}Selected:${RESET} ${GREEN}${SELECTED[*]}${RESET}"

# ---------- where ----------
# DESTS holds one or more directories that each receive <skill-name>/ subdirs.
#   global -> ~/.agents/skills AND ~/.claude/skills
#   local  -> <chosen dir>/skills
DESTS=()
scope="$(ask_choice "Install scope?" "global:Global (~/.agents/skills + ~/.claude/skills)" "local:Local (a project's skills/)")"

if [ "$scope" = "global" ]; then
  DESTS=("$HOME/.agents/skills" "$HOME/.claude/skills")
else
  loc="$(ask_choice "Local install location?" "cwd:Current directory ($PWD)" "other:Another directory")"
  if [ "$loc" = "cwd" ]; then
    TARGET_BASE="$PWD"
  else
    printf '\n%s' "${BOLD}Directory path:${RESET} > "
    IFS= read -r TARGET_BASE || die "cancelled"
    # expand a leading ~
    TARGET_BASE="${TARGET_BASE/#\~/$HOME}"
    [ -n "$TARGET_BASE" ] || die "no directory given"
    [ -d "$TARGET_BASE" ] || die "not a directory: $TARGET_BASE"
    TARGET_BASE="$(cd "$TARGET_BASE" && pwd)"
  fi
  DESTS=("$TARGET_BASE/skills")
fi

# ---------- how ----------
method="$(ask_choice "Install method?" "symlink:Symlink (stays in sync with this repo)" "copy:Copy (independent snapshot)")"

# ---------- confirm ----------
printf '\n%s\n' "${BOLD}Plan${RESET}"
info "  method: ${CYAN}${method}${RESET}"
info "  dest:   ${CYAN}${DESTS[*]}${RESET}"
info "  skills: ${CYAN}${SELECTED[*]}${RESET}"
confirm="$(ask_choice "Proceed?" "yes:Yes, install" "no:No, abort")"
[ "$confirm" = "yes" ] || die "aborted"

# ---------- install ----------
installed=0
for dest in "${DESTS[@]}"; do
  printf '\n%s\n' "${BOLD}-> ${dest}${RESET}"
  mkdir -p "$dest"
  for name in "${SELECTED[@]}"; do
    src="$SKILLS_SRC/$name"
    dst="$dest/$name"

    if [ -e "$dst" ] || [ -L "$dst" ]; then
      printf '%s' "${YELLOW}$name exists — overwrite? [y/N]${RESET} > "
      IFS= read -r ow || ow="n"
      case "$ow" in
        y|Y) rm -rf "$dst" ;;
        *) info "  ${DIM}skipped $name${RESET}"; continue ;;
      esac
    fi

    if [ "$method" = "symlink" ]; then
      ln -s "$src" "$dst"
      info "  ${GREEN}linked${RESET} $name"
    else
      cp -R "$src" "$dst"
      info "  ${GREEN}copied${RESET} $name"
    fi
    installed=$((installed+1))
  done
done

printf '\n%s\n' "${GREEN}${BOLD}Done.${RESET} Installed ${installed} skill instance(s) into: ${DESTS[*]}"

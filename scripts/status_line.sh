#!/bin/bash
set -euo pipefail

trap 'echo "(status error)"' ERR

blue="\033[38;2;30;102;245m"
yellow="\033[38;2;223;142;29m"
magenta="\033[38;2;136;57;239m"
red="\033[38;2;214;40;40m"
reset="\033[0m"

input=$(cat)
fields=()
while IFS= read -r line; do
  fields+=("$line")
done < <(echo "$input" | jq -r '.workspace.current_dir, (.workspace.git_dir // ""), (.context_window.remaining_percentage // "")' 2>/dev/null)

if [ $? -ne 0 ] || [ ${#fields[@]} -eq 0 ]; then
  printf '%b' "${red}(status_line.sh: json parse error)${reset}"
  exit 0
fi

dir="${fields[0]}"
git_dir="${fields[1]}"
remaining="${fields[2]}"

if [ -z "$dir" ]; then
  printf '%b' "${red}(status_line.sh: incomplete status)${reset}"
  exit 0
fi

branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

dirty_marker=""
if [ -n "$branch" ]; then
  if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    dirty_marker="${yellow}*${reset}"
  fi
fi

display_dir="${dir/#$HOME/~}"

# Line 1: path + dirty marker + optional context
status="${blue}${display_dir}${reset}${dirty_marker}"

if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
  status="${status} | ${magenta}ctx:${remaining}%${reset}"
fi

# Line 2: warnings (only if in a git repo)
warning=""
if [ -n "$branch" ]; then
  in_clones=false
  if [[ "$dir" == *"_clones/"* ]]; then
    in_clones=true
  fi

  if [ "$in_clones" = false ] && [ "$branch" != "main" ]; then
    warning="\n${red}⚠ Not in _clones but branch is \"${branch}\" (not main)${reset}"
  elif [ "$in_clones" = true ]; then
    # Extract clone dir name: the directory right after _clones/
    clone_dir=$(echo "$dir" | sed 's|.*_clones/||' | cut -d'/' -f1)
    if [ "$clone_dir" != "$branch" ]; then
      warning="\n${red}⚠ Clone dir \"${clone_dir}\" but branch is \"${branch}\"${reset}"
    fi
  fi
fi

printf '%b' "${status}${warning}"

#!/bin/bash
set -euo pipefail

trap 'echo "(status error)"' ERR

blue="\033[38;2;30;102;245m"
green="\033[38;2;64;160;43m"
yellow="\033[38;2;223;142;29m"
magenta="\033[38;2;136;57;239m"
gray="\033[38;2;76;79;105m"
red="\033[38;2;214;40;40m"
reset="\033[0m"

input=$(cat)
fields=()
while IFS= read -r line; do
  fields+=("$line")
done < <(echo "$input" | jq -r '.model.display_name, .workspace.current_dir, (.workspace.git_dir // ""), (.context_window.remaining_percentage // "")' 2>/dev/null)

if [ $? -ne 0 ] || [ ${#fields[@]} -eq 0 ]; then
  printf '%b' "${red}(status_line.sh: json parse error)${reset}"
  exit 0
fi

model="${fields[0]}"
dir="${fields[1]}"
git_dir="${fields[2]}"
remaining="${fields[3]}"

if [ -z "$model" ] || [ -z "$dir" ]; then
  printf '%b' "${red}(status_line.sh: incomplete status)${reset}"
  exit 0
fi

git_status=""
branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ -n "$branch" ]; then
  dirty_marker=""
  if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    dirty_marker="${yellow}*${reset}"
  fi
  git_status="${green}(${branch})${reset}${dirty_marker}"
elif [ -n "$git_dir" ] || git -C "$dir" rev-parse --git-dir &>/dev/null; then
  git_status="${red}(no git)${reset}"
fi

display_dir="${dir/#$HOME/~}"

status="${gray}${model}${reset} | ${blue}${display_dir}${reset}"

if [ -n "$git_status" ]; then
  status="${status} ${git_status}"
fi

if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
  status="${status} | ${magenta}ctx:${remaining}%${reset}"
fi

printf '%b' "$status"

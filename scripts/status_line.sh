#!/bin/bash
# Status line command for Claude Code
# Displays: {model} in {dir} {branch}* | ctx:XX%
# With RGB ANSI colors

set -euo pipefail

trap 'echo "(status error)"' ERR

# ANSI color codes (RGB format: \033[38;2;R;G;Bm)
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

# Fallback to minimal status if jq parsing gave us nothing
if [ -z "$model" ] || [ -z "$dir" ]; then
  printf '%b' "${red}(status_line.sh: incomplete status)${reset}"
  exit 0
fi

# Add git branch with dirty status if in a git repo
# Try to detect git repo even if git_dir not provided in JSON
git_status=""
branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

if [ -n "$branch" ]; then
  dirty_marker=""
  if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    dirty_marker="${yellow}*${reset}"
  fi
  git_status="${green}(${branch})${reset}${dirty_marker}"
elif [ -n "$git_dir" ] || git -C "$dir" rev-parse --git-dir &>/dev/null; then
  # Git repo exists but branch detection failed
  git_status="${red}(no git)${reset}"
fi

# CI status from cache
ci_status=""
ci_cache_file="$HOME/.claude/ci_status_cache/$branch"
if [ -n "$branch" ] && [ -f "$ci_cache_file" ]; then
  IFS='|' read -r ci_state ci_ts < "$ci_cache_file"
  now=$(date +%s)
  age=$(( now - ci_ts ))
  if [ "$age" -lt 1800 ]; then
    case "$ci_state" in
      pass)    ci_status="${green}CI:ok${reset}" ;;
      fail)    ci_status="${red}CI:fail${reset}" ;;
      running) ci_status="${yellow}CI:...${reset}" ;;
    esac
  fi
fi

# Replace home directory with ~ for display
display_dir="${dir/#$HOME/~}"

# Build status line
status="${gray}${model}${reset} | ${blue}${display_dir}${reset}"

# Add git status if available
if [ -n "$git_status" ]; then
  status="${status} ${git_status}"
fi

if [ -n "$ci_status" ]; then
  status="${status} | ${ci_status}"
fi

# Add context percentage if available
if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
  status="${status} | ${magenta}ctx:${remaining}%${reset}"
fi

printf '%b' "$status"

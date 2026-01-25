#!/bin/bash
# Status line command for Claude Code
# Displays: {model} in {dir} {branch}* | ctx:XX% 
# With RGB ANSI colors

# ANSI color codes (RGB format: \033[38;2;R;G;Bm)
blue="\033[38;2;30;102;245m"
green="\033[38;2;64;160;43m"
yellow="\033[38;2;223;142;29m"
magenta="\033[38;2;136;57;239m"
gray="\033[38;2;76;79;105m"
reset="\033[0m"

input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name')
dir=$(echo "$input" | jq -r '.workspace.current_dir')
git_dir=$(echo "$input" | jq -r '.workspace.git_dir // empty')
remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')

# Build status line
status="${gray}${model}${reset} in ${blue}${dir}${reset}"

# Add git branch with dirty status if in a git repo
if [ -n "$git_dir" ]; then
  branch=$(echo "$input" | jq -r '.workspace.git_branch // empty')
  if [ -n "$branch" ]; then
    dirty=$(echo "$input" | jq -r '.workspace.git_dirty // false')
    dirty_marker=""
    if [ "$dirty" = "true" ]; then
      dirty_marker="${yellow}*${reset}"
    fi
    status="${status} ${green}${branch}${reset}${dirty_marker}"
  fi
fi

# Add context percentage if available
if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
  status="${status} | ${magenta}ctx:${remaining}%${reset}"
fi


printf '%b' "$status"

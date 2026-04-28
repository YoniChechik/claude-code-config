#!/bin/bash
set -euo pipefail

trap 'echo "(status error)"' ERR

blue="\033[38;2;30;102;245m"
yellow="\033[38;2;223;142;29m"
magenta="\033[38;2;136;57;239m"
red="\033[38;2;214;40;40m"
green="\033[38;2;64;160;43m"
reset="\033[0m"

input=$(cat)
if ! parsed=$(printf '%s' "$input" | jq -r '
  .workspace.current_dir,
  (.workspace.git_dir // ""),
  (.context_window.remaining_percentage // ""),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at // "")
' 2>/dev/null); then
  printf '%b' "${red}(status_line.sh: json parse error)${reset}"
  exit 0
fi

# Split parsed output into fields array.
IFS=$'\n' read -r -d '' -a fields <<< "$parsed" || true

if [ ${#fields[@]} -eq 0 ]; then
  printf '%b' "${red}(status_line.sh: json parse error)${reset}"
  exit 0
fi

dir="${fields[0]}"
git_dir="${fields[1]}"
remaining="${fields[2]}"
five_hr_used="${fields[3]}"
five_hr_resets_at="${fields[4]}"

if [ -z "$dir" ]; then
  printf '%b' "${red}(status_line.sh: incomplete status)${reset}"
  exit 0
fi

branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
# Sanitized branch name for /tmp file paths (matches ci_watch_persistent.sh).
# Branches like "feature/foo" produce paths like /tmp/ci_watch_state_feature/foo
# which fail because the parent dir doesn't exist. Replace "/" with "__".
branch_key="${branch//\//__}"

# Resolve session identity for state file lookup.
_cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null || true)
[[ -z "$_cwd" ]] && _cwd="$PWD"
_cwd_hash=$(printf '%s' "$_cwd" | shasum -a 1 | cut -c1-12)
_sid8=$(cat "$HOME/.claude/cache/cwd-session/$_cwd_hash" 2>/dev/null || printf '')

if [[ -n "$_sid8" ]]; then
    slot="${branch_key}_${_sid8}"
else
    # Fallback: legacy filename (no SID8) for sessions started before this change.
    slot="${branch_key}"
fi

dirty_marker=""
if [ -n "$branch" ]; then
  if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    dirty_marker="${yellow}*${reset}"
  fi
fi

# Build a short display: "repo-name / clone-name" or just "repo-name"
if [[ "$dir" == *"/_clones/"* ]]; then
  repo_name=$(echo "$dir" | sed 's|/_clones/.*||' | xargs basename)
  clone_name=$(echo "$dir" | sed 's|.*/_clones/||' | cut -d'/' -f1)
  display_dir="${repo_name} / ${clone_name}"
else
  # Try to get the git repo root name, fall back to basename of dir
  repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")
  display_dir=$(basename "$repo_root")
fi

# Line 1: path + dirty marker + optional context
status="${blue}${display_dir}${reset}${dirty_marker}"

# Line 2: context window + 5h rate limit
info_line=""

if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
  remaining_rounded=$(printf "%.0f" "$remaining")
  info_line="${magenta}session: ${remaining_rounded}%${reset}"
fi

if [ -n "$five_hr_used" ] && [ "$five_hr_used" != "null" ]; then
  five_hr_remaining=$(printf "%.0f" "$(echo "100 - $five_hr_used" | bc)")
  five_hr_part="${yellow}5h: ${five_hr_remaining}%${reset}"
  if [ -n "$five_hr_resets_at" ] && [ "$five_hr_resets_at" != "null" ]; then
    reset_time=$(date -r "$five_hr_resets_at" "+%H:%M" 2>/dev/null || date -d "@${five_hr_resets_at}" "+%H:%M" 2>/dev/null || echo "")
    if [ -n "$reset_time" ]; then
      five_hr_part="${five_hr_part} ${yellow}(${reset_time})${reset}"
    fi
  fi
  if [ -n "$info_line" ]; then
    info_line="${info_line} | ${five_hr_part}"
  else
    info_line="${five_hr_part}"
  fi
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

# Line 3: clickable PR link (if branch has an open PR)
# Read from the cache file written by ci_watch_persistent.sh — no gh call here.
pr_line=""
if [ -n "$branch" ] && [ "$branch" != "main" ]; then
  pr_cache_file="/tmp/ci_watch_pr_${slot}"
  if [ -f "$pr_cache_file" ]; then
    # Freshness check: ignore PR cache files older than 10 minutes to avoid
    # leaking stale state from previous sessions / dead watchers.
    _now=$(date +%s)
    # stat -f %m is macOS; stat -c %Y is Linux fallback.
    _mtime=$(stat -f %m "$pr_cache_file" 2>/dev/null \
             || stat -c %Y "$pr_cache_file" 2>/dev/null \
             || printf '0')
    _age=$(( _now - _mtime ))
    if [ "$_age" -gt 600 ]; then
      pr_cache_file=""
    fi
  fi
  if [ -n "$pr_cache_file" ] && [ -f "$pr_cache_file" ]; then
    pr_json=$(cat "$pr_cache_file" 2>/dev/null || echo "")
    pr_url=$(printf '%s' "$pr_json" | jq -r '.url // ""' 2>/dev/null)
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number // ""' 2>/dev/null)
    pr_state=$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null)
    if [ -n "$pr_url" ] && [ "$pr_url" != "null" ] && [ -n "$pr_number" ] && [ "$pr_number" != "null" ] && [ "$pr_state" = "OPEN" ]; then
      pr_line="\e]8;;${pr_url}\aPR #${pr_number}\e]8;;\a"
    fi
  fi

  # Append CI hook state if available
  if [ -n "$branch" ]; then
    ci_state_file="/tmp/ci_watch_state_${slot}"
    if [ -f "$ci_state_file" ]; then
      # Watcher updates this file every POLL_INTERVAL (~5s). If older than
      # 120s (2x typical max wait), the watcher likely died — treat as orphan.
      _now=$(date +%s)
      _mtime=$(stat -f %m "$ci_state_file" 2>/dev/null \
               || stat -c %Y "$ci_state_file" 2>/dev/null \
               || printf '0')
      _age=$(( _now - _mtime ))
      if [ "$_age" -gt 120 ]; then
        ci_state_file=""
      fi
    fi
    if [ -n "$ci_state_file" ] && [ -f "$ci_state_file" ]; then
      ci_state=$(cat "$ci_state_file" 2>/dev/null || echo "")
      case "$ci_state" in
        running)  ci_display="${yellow}ci: running${reset}" ;;
        passed)   ci_display="${green}ci: passed${reset}" ;;
        failed)   ci_display="${red}ci: failed${reset}" ;;
        conflict) ci_display="${red}ci: conflict${reset}" ;;
        behind)   ci_display="${yellow}ci: behind${reset}" ;;
        merging)  ci_display="${yellow}ci: merging to main...${reset}" ;;
        *)        ci_display="" ;;
      esac
      if [ -n "$ci_display" ] && [ -n "$pr_line" ]; then
        pr_line="${pr_line} | ${ci_display}"
      elif [ -n "$ci_display" ]; then
        pr_line="${ci_display}"
      fi
    fi
  fi
fi

current_time=$(date +%H:%M:%S)
time_part="${blue}${current_time}${reset}"

output="${status}${warning}"
if [ -n "$info_line" ]; then
  output="${output}\n${info_line}"
fi
if [ -n "$pr_line" ]; then
  output="${output}\n${pr_line} | ${time_part}"
elif [ -n "$info_line" ]; then
  # Time goes on the info_line (last line) — rebuild it with time appended
  output="${status}${warning}\n${info_line} | ${time_part}"
else
  output="${status}${warning}\n${time_part}"
fi
printf '%b' "$output"

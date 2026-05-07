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
  (.rate_limits.five_hour.resets_at // ""),
  (.session_id // "")
' 2>/dev/null); then
  printf '%b' "${red}(status_line.sh: json parse error)${reset}"
  exit 0
fi

# Split parsed output into fields array.
# Note: we read line-by-line (rather than `read -d ''`) so each jq line
# becomes its own array element, and we tolerate jq emitting fewer than 5
# lines (e.g. when the payload is missing fields entirely).
fields=()
while IFS= read -r _line; do
  fields+=("$_line")
done <<< "$parsed"

# Safe per-index extraction — missing indices default to empty so set -u
# (nounset) doesn't kill the script.
dir="${fields[0]-}"
git_dir="${fields[1]-}"
remaining="${fields[2]-}"
five_hr_used="${fields[3]-}"
five_hr_resets_at="${fields[4]-}"
session_id="${fields[5]-}"

# Treat literal "null" (jq's output for a missing top-level field with no
# `// ""` fallback) the same as empty.
[[ "$dir" == "null" ]] && dir=""
[[ "$git_dir" == "null" ]] && git_dir=""
[[ "$remaining" == "null" ]] && remaining=""
[[ "$five_hr_used" == "null" ]] && five_hr_used=""
[[ "$five_hr_resets_at" == "null" ]] && five_hr_resets_at=""
[[ "$session_id" == "null" ]] && session_id=""

# Fall back to PWD so we still render something useful when the harness
# payload doesn't include workspace.current_dir.
if [ -z "$dir" ]; then
  dir="$PWD"
fi

branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
slot="$session_id"

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
# Read from the cache file written by ci_watch.py — no gh call here.
pr_line=""
pr_json=""
pr_cache_file=""
if [ -n "$slot" ]; then
  pr_cache_file="/tmp/ci_watch_pr_${slot}"
  if [ -n "$branch" ] && [ "$branch" != "main" ] && [ -f "$pr_cache_file" ]; then
    pr_json=$(cat "$pr_cache_file" 2>/dev/null || echo "")
    pr_url=$(printf '%s' "$pr_json" | jq -r '.url // ""' 2>/dev/null)
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number // ""' 2>/dev/null)
    pr_state=$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null)
    if [ -n "$pr_url" ] && [ "$pr_url" != "null" ] && [ -n "$pr_number" ] && [ "$pr_number" != "null" ] && [ "$pr_state" = "OPEN" ]; then
      pr_line="\e]8;;${pr_url}\aPR #${pr_number}\e]8;;\a"
    fi
  fi

  ci_state_file="/tmp/ci_watch_state_${slot}"
  if [ -f "$ci_state_file" ]; then
    _ci_state_raw=$(cat "$ci_state_file" 2>/dev/null || true)
    ci_stored_branch="${_ci_state_raw%%:*}"
    ci_state_only="${_ci_state_raw#*:}"
    if [[ "$ci_stored_branch" == "$_ci_state_raw" ]]; then
      ci_stored_branch=""
      ci_state_only="$_ci_state_raw"
    fi

    # For terminal states, no watcher is expected — show result forever.
    # For active states, verify the watcher process is still alive.
    _watcher_alive=false
    case "$ci_state_only" in
      passed|failed|merged-passed|merged-failed|timeout)
        _watcher_alive=true
        ;;
      *)
        _lock_file="${ci_state_file/ci_watch_state/ci_watch_lock}"
        _watcher_pid=$(cat "$_lock_file" 2>/dev/null || true)
        if [[ -n "$_watcher_pid" ]] && kill -0 "$_watcher_pid" 2>/dev/null \
           && ps -p "$_watcher_pid" -o args= 2>/dev/null | grep -q "ci_watch"; then
          _watcher_alive=true
        fi
        ;;
    esac

    if [[ "$_watcher_alive" == false && -n "$ci_state_only" ]]; then
      ci_display="${red}⚠ ci watcher died${reset}"
    else
      ci_state="$ci_state_only"
      if [ "$ci_state" = "passed" ] && [ -f "$pr_cache_file" ]; then
        _merge_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // ""' 2>/dev/null)
        case "$_merge_state" in
          BEHIND)              ci_state="behind" ;;
          DIRTY|CONFLICTING)   ci_state="conflict" ;;
        esac
      fi
      case "$ci_state" in
        running)       ci_display="${yellow}ci: running${reset}" ;;
        passed)        ci_display="${green}ci: passed${reset}" ;;
        failed)        ci_display="${red}ci: failed${reset}" ;;
        conflict)      ci_display="${red}ci: conflict${reset}" ;;
        behind)        ci_display="${yellow}ci: behind${reset}" ;;
        no-runs)       ci_display="${yellow}⚠ no runs${reset}" ;;
        timeout)       ci_display="${red}⚠ merge timeout${reset}" ;;
        merging)       ci_display="${yellow}ci: merging to main...${reset}" ;;
        merged-passed) ci_display="${green}✓ main CI passed${reset}" ;;
        merged-failed) ci_display="${red}✗ main CI failed${reset}" ;;
        *)             ci_display="" ;;
      esac
    fi

    if [[ -n "$ci_display" && -n "$ci_stored_branch" && -n "$branch" \
          && "$ci_stored_branch" != "$branch" ]]; then
      ci_display="${ci_display} ${magenta}(${ci_stored_branch})${reset}"
    fi

    if [ -n "$ci_display" ] && [ -n "$pr_line" ]; then
      pr_line="${pr_line} | ${ci_display}"
    elif [ -n "$ci_display" ]; then
      pr_line="${ci_display}"
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

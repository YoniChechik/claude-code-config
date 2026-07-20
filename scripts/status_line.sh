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

# Terminal CI states: rendered forever, no liveness check, no elapsed timer.
# Single source of truth for both the liveness gate and the timer gate below.
_ci_is_terminal_state() {
  case "$1" in
    passed|failed|merged-passed|merged-failed|timeout|no-ci|no-main-ci|closed|stuck-pending) return 0 ;;
    *) return 1 ;;
  esac
}

# PR blocks: one stacked row per watched branch. ci_watch.py keys every state
# file as ci_watch_state_<slot>__<sanitized_branch>, so we glob all of this
# session's watchers and render each as its own row. No gh call here — data
# comes from the watcher's cache files.
pr_block=""
if [ -n "$slot" ]; then
  # One clock read per render, shared by every row's elapsed-time calc.
  _now=$(date +%s)
  # nullglob so an unmatched glob yields zero iterations, not a literal string.
  shopt -s nullglob
  for ci_state_file in /tmp/ci_watch_state_"${slot}"__*; do
    _ci_state_raw=$(cat "$ci_state_file" 2>/dev/null || true)
    [ -n "$_ci_state_raw" ] || continue

    # Parse the 3-field "<branch>:<state>:<epoch>" line. Tolerate a legacy
    # 2-field line (no epoch → no timer).
    ci_stored_branch="${_ci_state_raw%%:*}"
    _rest="${_ci_state_raw#*:}"
    if [[ "$ci_stored_branch" == "$_ci_state_raw" ]]; then
      # No colon at all — treat the whole thing as the state.
      ci_stored_branch=""
      ci_state_only="$_ci_state_raw"
      ci_epoch=""
    else
      ci_state_only="${_rest%%:*}"
      if [[ "$ci_state_only" == "$_rest" ]]; then
        # Only two fields — no epoch.
        ci_epoch=""
      else
        ci_epoch="${_rest##*:}"
      fi
    fi

    # Sibling pr-cache and lock files share the composite suffix.
    pr_cache_file="${ci_state_file/ci_watch_state/ci_watch_pr}"
    _lock_file="${ci_state_file/ci_watch_state/ci_watch_lock}"

    # Clickable PR link, only for an OPEN PR (same as before). One jq pass pulls
    # every field this row needs (url/number/state for the link, mergeStateStatus
    # for the behind/conflict refinement) so we fork jq once, not 3-4 times/row.
    pr_line=""
    pr_json=""
    pr_merge_state=""
    if [ -f "$pr_cache_file" ]; then
      pr_json=$(cat "$pr_cache_file" 2>/dev/null || echo "")
      IFS=$'\t' read -r pr_url pr_number pr_state pr_merge_state < <(
        printf '%s' "$pr_json" \
          | jq -r '[.url // "", .number // "", .state // "", .mergeStateStatus // ""] | @tsv' 2>/dev/null
      )
      if [ -n "$pr_url" ] && [ "$pr_url" != "null" ] && [ -n "$pr_number" ] && [ "$pr_number" != "null" ] && [ "$pr_state" = "OPEN" ]; then
        pr_line="\e]8;;${pr_url}\aPR #${pr_number}\e]8;;\a"
      fi
    fi

    # Terminal states show forever with no timer and no liveness check; active
    # states verify the watcher process is alive.
    _watcher_alive=false
    if _ci_is_terminal_state "$ci_state_only"; then
      _watcher_alive=true
    else
      _watcher_pid=$(cat "$_lock_file" 2>/dev/null || true)
      if [[ -n "$_watcher_pid" ]] && kill -0 "$_watcher_pid" 2>/dev/null \
         && ps -p "$_watcher_pid" -o args= 2>/dev/null | grep -q "ci_watch"; then
        _watcher_alive=true
      fi
    fi

    if [[ "$_watcher_alive" == false && -n "$ci_state_only" ]]; then
      ci_display="${red}⚠ ci watcher died${reset}"
    else
      ci_state="$ci_state_only"
      if [ "$ci_state" = "passed" ]; then
        case "$pr_merge_state" in
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
        no-ci)         ci_display="${green}ci: none${reset}" ;;
        no-main-ci)    ci_display="${green}ci: no main ci${reset}" ;;
        closed)        ci_display="${magenta}ci: closed${reset}" ;;
        stuck-pending) ci_display="${red}⚠ checks stuck${reset}" ;;
        timeout)       ci_display="${red}⚠ merge timeout${reset}" ;;
        merging)       ci_display="${yellow}ci: merging to main...${reset}" ;;
        merged-passed) ci_display="${green}✓ main CI passed${reset}" ;;
        merged-failed) ci_display="${red}✗ main CI failed${reset}" ;;
        *)             ci_display="" ;;
      esac
    fi

    # Elapsed timer for ACTIVE (non-terminal) states only, so terminal rows
    # never show a timer (same gate as the liveness check above).
    timer_part=""
    if ! _ci_is_terminal_state "$ci_state_only" \
       && [[ "$ci_epoch" =~ ^[0-9]+$ ]] && [ "$ci_epoch" -gt 0 ]; then
      _elapsed=$((_now - ci_epoch))
      if [ "$_elapsed" -lt 0 ]; then
        _elapsed=0
      fi
      if [ "$_elapsed" -lt 60 ]; then
        timer_part="${_elapsed}s"
      elif [ "$_elapsed" -lt 3600 ]; then
        printf -v timer_part '%dm%02ds' $((_elapsed / 60)) $((_elapsed % 60))
      else
        printf -v timer_part '%dh%02dm' $((_elapsed / 3600)) $(((_elapsed % 3600) / 60))
      fi
      timer_part="${blue}${timer_part}${reset}"
    fi

    # Row identity: when there is no OPEN PR link, prefix the stored branch so
    # stacked rows stay distinguishable.
    row_head="$pr_line"
    if [ -z "$row_head" ] && [ -n "$ci_stored_branch" ]; then
      row_head="${ci_stored_branch}"
    fi

    # Assemble this block: <head> | ci: <state> | <timer>
    _row=""
    if [ -n "$row_head" ]; then
      _row="$row_head"
    fi
    if [ -n "$ci_display" ]; then
      if [ -n "$_row" ]; then
        _row="${_row} | ${ci_display}"
      else
        _row="${ci_display}"
      fi
    fi
    if [ -n "$timer_part" ] && [ -n "$_row" ]; then
      _row="${_row} | ${timer_part}"
    fi

    if [ -n "$_row" ]; then
      if [ -n "$pr_block" ]; then
        pr_block="${pr_block}\n${_row}"
      else
        pr_block="${_row}"
      fi
    fi
  done
  shopt -u nullglob
fi

output="${status}${warning}"
if [ -n "$info_line" ]; then
  output="${output}\n${info_line}"
fi
if [ -n "$pr_block" ]; then
  output="${output}\n${pr_block}"
fi
printf '%b' "$output"

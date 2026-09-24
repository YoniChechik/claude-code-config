#!/bin/bash
set -euo pipefail

trap 'echo "(status error)"' ERR

# Shared helpers: _session_name_read / _sanitize_and_cap (the single
# implementation of the session-name sanitize-and-cap contract). Sourcing only
# defines functions, so it costs no subprocess on this ~1/second hot path.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

# Colors are expanded ONCE, here, via $'...' ANSI-C quoting — never left as
# literal "\033" text for a `printf '%b'` at the end to convert. That final %b
# would also re-expand backslash sequences sitting inside INTERPOLATED data
# (a session name, an org name, a PR url), turning printable text such as
# `\033]0;PWNED\007` into a genuine terminal escape sequence. With the escapes
# already real here, the output stage is a plain `printf '%s'` that treats
# every interpolated value as inert text.
blue=$'\033[38;2;30;102;245m'
yellow=$'\033[38;2;223;142;29m'
magenta=$'\033[38;2;136;57;239m'
red=$'\033[38;2;214;40;40m'
green=$'\033[38;2;64;160;43m'
cyan=$'\033[38;2;4;165;229m'
reset=$'\033[0m'
newline=$'\n'

input=$(cat)
if ! parsed=$(printf '%s' "$input" | jq -r '
  .workspace.current_dir,
  (.workspace.git_dir // ""),
  (.context_window.remaining_percentage // ""),
  (.rate_limits.five_hour.used_percentage // ""),
  (.rate_limits.five_hour.resets_at // ""),
  (.session_id // "")
' 2>/dev/null); then
  printf '%s' "${red}(status_line.sh: json parse error)${reset}"
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

# Session name: read from the per-session sidecar file written by the
# /session-name skill (~/.claude/skills/session-name/SKILL.md). This file is
# the only source of truth for the session-name segment below — no fallback
# to the hook payload's native session_name field, worktree name, or branch.
#
# Keyed on this payload's own .session_id, so `_session_name_read` is called
# with an explicit session id rather than the ambient CLAUDE_CODE_SESSION_ID.
# `|| true` keeps a helper failure of any kind (broken python3, unreadable
# file) to "no segment shown" instead of aborting the whole status line under
# the `set -e` / ERR trap above.
session_name=$(_session_name_read "$session_id" 2>/dev/null || true)

# Wakeup indicator: read the sidecar written by
# scripts/stop__wakeup_status.sh, which mirrors the Stop hook input's
# session_crons array (armed ScheduleWakeup/CronCreate/`/loop` timers) into a
# per-session file, keyed the same way as the session-name sidecar above.
# `|| true` keeps a helper failure of any kind to "no segment shown" instead
# of aborting the whole status line under the `set -e` / ERR trap above.
wakeup_raw=$(_wakeup_next_read "$session_id" 2>/dev/null || true)

dirty_marker=""
if [ -n "$branch" ]; then
  if ! git -C "$dir" diff --quiet 2>/dev/null || ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
    dirty_marker="${yellow}*${reset}"
  fi
fi

# Build a short display: "repo-name / session-name" or just "repo-name".
# The session-name segment comes solely from the sidecar file read above —
# no fallback to worktree/branch name when it's absent or empty.
if [[ "$dir" == *"/.claude/worktrees/"* ]]; then
  repo_name=$(echo "$dir" | sed 's|/\.claude/worktrees/.*||' | xargs basename)
else
  # Try to get the git repo root name, fall back to basename of dir
  repo_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || echo "$dir")
  repo_name=$(basename "$repo_root")
fi

if [ -n "$session_name" ]; then
  display_dir="${repo_name} / ${session_name}"
else
  display_dir="${repo_name}"
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

# Line 2b: current Claude org, shown directly under the 5h rate-limit line.
# Source: oauthAccount.organizationName in ~/.claude.json (not part of the
# statusLine JSON payload, so we read it from disk).
org_line=""
if [ -n "$five_hr_used" ] && [ "$five_hr_used" != "null" ]; then
  org_name=$(jq -r '.oauthAccount.organizationName // empty' "$HOME/.claude.json" 2>/dev/null || echo "")
  if [ -n "$org_name" ]; then
    org_line="${green}org: ${org_name}${reset}"
  fi
fi

# Line 2c: wakeup indicator, shown only while a wakeup is actually armed AND
# still in the future. _wakeup_next_read already refuses to echo a past
# epoch, so reaching this block with non-empty $wakeup_raw means "still
# armed" -- no further staleness check needed here.
wakeup_line=""
if [ -n "$wakeup_raw" ]; then
  wakeup_epoch="${wakeup_raw%%$'\t'*}"
  wakeup_label="${wakeup_raw#*$'\t'}"
  # No tab found (a malformed read) -- the `#*` strip is then a no-op, so
  # label would equal the whole raw value. Treat that as "no label" rather
  # than rendering the raw payload.
  if [ "$wakeup_label" = "$wakeup_raw" ]; then
    wakeup_label=""
  fi
  wakeup_time=$(date -r "$wakeup_epoch" "+%H:%M" 2>/dev/null || date -d "@${wakeup_epoch}" "+%H:%M" 2>/dev/null || echo "")
  if [ -n "$wakeup_time" ]; then
    wakeup_line="${cyan}⏰ next: ${wakeup_time}${reset}"
    if [ -n "$wakeup_label" ]; then
      wakeup_line="${wakeup_line} ${cyan}(${wakeup_label})${reset}"
    fi
  fi
fi

# CI-watcher status rendering was removed along with the old ci_watch.py
# daemon: the new one-shot watchers (ci_watch.sh) report through Bash
# background-task notifications instead of a polled status-line row.
pr_lines=()
output="${status}"
if [ -n "$info_line" ]; then
  output="${output}${newline}${info_line}"
fi
if [ -n "$org_line" ]; then
  output="${output}${newline}${org_line}"
fi
if [ -n "$wakeup_line" ]; then
  output="${output}${newline}${wakeup_line}"
fi
# ${#pr_lines[@]} guard, not "${pr_lines[@]:-}": expanding an empty array is an
# unbound-variable error under `set -u` on bash 3.2 (the macOS system bash).
if [ "${#pr_lines[@]}" -gt 0 ]; then
  for _row in "${pr_lines[@]}"; do
    output="${output}${newline}${_row}"
  done
fi
# '%s', never '%b': every escape in $output is already a real byte, and %b
# would re-interpret backslash text carried in interpolated values.
printf '%s' "$output"

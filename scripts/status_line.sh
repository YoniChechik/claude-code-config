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
reset=$'\033[0m'
newline=$'\n'
# Field separator for the finished-PR records built below. A literal tab, so
# `sort -t` and `awk -F` agree with the `read` that consumes them.
tab=$'\t'

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
# with an explicit session id rather than via _display_title's
# CLAUDE_CODE_SESSION_ID. `|| true` keeps a helper failure of any kind (broken
# python3, unreadable file) to "no segment shown" instead of aborting the whole
# status line under the `set -e` / ERR trap above.
session_name=$(_session_name_read "$session_id" 2>/dev/null || true)

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

# --- Lines 3+: one row per CI watcher, then the session's finished PRs -------
# A session can run several watchers at once — one per branch — so this renders
# one row per watcher, all read from the files ci_watch.py writes. No gh call.

# The literal words "post merge", hyperlinked to GitHub's check list for the
# merge commit. Args: <repoUrl> <merge commit oid>. Falls back to plain text
# when either is missing, so a stale PR cache degrades to an unlinked label.
post_merge_label() {
  local repo_url="$1" oid="$2"
  if [ -n "$repo_url" ] && [ "$repo_url" != "null" ] \
     && [ -n "$oid" ] && [ "$oid" != "null" ]; then
    printf '%s' $'\033]8;;'"${repo_url}/commit/${oid}/checks"$'\a'"post merge"$'\033]8;;\a'
  else
    printf '%s' "post merge"
  fi
  return 0
}

# Render ONE watcher's row from its slot ($1). Echoes the row, or nothing at all
# when the row must be hidden.
render_ci_row() {
  local one_slot="$1"
  local state_file="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_state_${one_slot}"
  local pr_cache_file="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_pr_${one_slot}"
  local lock_file="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_lock_${one_slot}"

  local raw state_only detached=false
  raw=$(cat "$state_file" 2>/dev/null || true)
  [ -n "$raw" ] || return 0
  # "<branch>:<state>". A line with no colon carries no branch prefix, so the
  # whole line is the state.
  if [[ "$raw" == *:* ]]; then
    state_only="${raw#*:}"
  else
    state_only="$raw"
  fi

  # ci_watch.py appends ":monitor-detached@<epoch>" once its stdout writes start
  # failing: the process still polls CI, but every notification it emits is
  # dropped. Strip the field so the state value still matches below.
  case "$state_only" in
    *:monitor-detached@*)
      detached=true
      state_only="${state_only%%:monitor-detached@*}"
      ;;
  esac

  # A PR whose post-merge CI went green belongs to the finished-PRs row below,
  # not to a row of its own.
  if [ "$state_only" = "merged-passed" ]; then
    return 0
  fi

  # PR metadata. Absent until the watcher has actually found a PR.
  local pr_json="" pr_url="" pr_number="" repo_url="" merge_oid="" pr_part=""
  if [ -f "$pr_cache_file" ]; then
    pr_json=$(cat "$pr_cache_file" 2>/dev/null || echo "")
    pr_url=$(printf '%s' "$pr_json" | jq -r '.url // ""' 2>/dev/null || echo "")
    pr_number=$(printf '%s' "$pr_json" | jq -r '.number // ""' 2>/dev/null || echo "")
    repo_url=$(printf '%s' "$pr_json" | jq -r '.repoUrl // ""' 2>/dev/null || echo "")
    merge_oid=$(printf '%s' "$pr_json" | jq -r '.mergeCommit.oid // ""' 2>/dev/null || echo "")
  fi
  if [ -n "$pr_url" ] && [ "$pr_url" != "null" ] \
     && [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    # OSC 8 hyperlink, with the escapes already expanded (see the color note at
    # the top) so the render stage never has to interpret backslashes.
    pr_part=$'\033]8;;'"${pr_url}"$'\a'"PR #${pr_number}"$'\033]8;;\a'
  fi

  # For terminal states no watcher is expected — show the result forever. For
  # active states, this slot's OWN lockfile decides whether it is still alive.
  local alive=false pid
  case "$state_only" in
    passed|failed|merged-failed|timeout|no-ci|no-main-ci|no-ci-configured)
      alive=true
      ;;
    *)
      pid=$(cat "$lock_file" 2>/dev/null || true)
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
         && ps -p "$pid" -o args= 2>/dev/null | grep -q "ci_watch"; then
        alive=true
      fi
      ;;
  esac

  local ci_display="" ci_state merge_state
  if [ "$alive" = false ] && [ -n "$state_only" ]; then
    ci_display="${red}⚠ ci watcher died${reset}"
  elif [ "$detached" = true ]; then
    # Alive, but mute: distinct from both "died" and a plain running state.
    ci_display="${red}⚠ ci notifications lost — restart watcher${reset}"
  else
    ci_state="$state_only"
    if [ "$ci_state" = "passed" ] && [ -n "$pr_json" ]; then
      merge_state=$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus // ""' 2>/dev/null || echo "")
      case "$merge_state" in
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
      no-ci-configured) ci_display="${green}ci: no CI configured — safe to merge${reset}" ;;
      timeout)       ci_display="${red}⚠ merge timeout${reset}" ;;
      # Post-merge states carry a "post merge" label instead of "ci", linked to
      # GitHub's check list for the merge commit.
      merging)       ci_display="${yellow}$(post_merge_label "$repo_url" "$merge_oid"): running${reset}" ;;
      merged-failed) ci_display="${red}$(post_merge_label "$repo_url" "$merge_oid"): failed${reset}" ;;
      *)             ci_display="" ;;
    esac
  fi

  if [ -n "$ci_display" ] && [ -n "$pr_part" ]; then
    printf '%s' "${pr_part} | ${ci_display}"
  elif [ -n "$ci_display" ]; then
    printf '%s' "$ci_display"
  elif [ -n "$pr_part" ]; then
    printf '%s' "$pr_part"
  fi
  return 0
}

# The session-level finished-PRs row: every PR that merged AND went green on
# post-merge CI, newest first. Every watcher of the session appends to one
# append-only JSON-Lines file; dedup and ordering happen HERE, at render time,
# so concurrently-finishing watchers never have to read-modify-write.
render_finished_prs() {
  local session_id="$1"
  local file="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch_finished_${session_id}"
  [ -f "$file" ] || return 0

  # Parse each line on its own so a torn write from a killed watcher is SKIPPED
  # rather than aborting the whole row. jq emits "<ts>\t<number>\t<url>".
  local entries="" line parsed
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    parsed=$(printf '%s' "$line" | jq -r '
      select(type == "object")
      | select((.number | type) == "number")
      | select((.ts | type) == "number")
      | select((.url | type) == "string")
      | "\(.ts)\t\(.number)\t\(.url)"' 2>/dev/null || true)
    [ -n "$parsed" ] || continue
    entries="${entries}${parsed}${newline}"
  done < "$file"
  [ -n "$entries" ] || return 0

  # Dedupe by PR number keeping the newest ts (relaunching a watcher on an
  # already-finished PR appends a second line for it), then order newest first.
  local sorted
  sorted=$(printf '%s' "$entries" \
    | sort -t"$tab" -k2,2n -k1,1nr \
    | awk -F"$tab" '!seen[$2]++' \
    | sort -t"$tab" -k1,1nr || true)
  [ -n "$sorted" ] || return 0

  local out="" number url link
  while IFS="$tab" read -r _ number url; do
    [ -n "$number" ] || continue
    link=$'\033]8;;'"${url}"$'\a'"#${number}"$'\033]8;;\a'
    if [ -n "$out" ]; then
      out="${out}, ${link}"
    else
      out="$link"
    fi
  done <<< "$sorted"
  [ -n "$out" ] || return 0
  printf '%s' "${green}finished PRs:${reset} ${out}"
  return 0
}

pr_lines=()
if [ -n "$session_id" ]; then
  # Discovery goes through _notify.sh's shared helper, so "which watchers does
  # this session have" is defined in exactly one place.
  while IFS= read -r _state_file; do
    [ -n "$_state_file" ] || continue
    _row=$(render_ci_row "${_state_file##*/ci_watch_state_}")
    if [ -n "$_row" ]; then
      pr_lines+=("$_row")
    fi
  done < <(_ci_watch_session_state_files "$session_id")

  _finished_row=$(render_finished_prs "$session_id")
  if [ -n "$_finished_row" ]; then
    pr_lines+=("$_finished_row")
  fi
fi

output="${status}"
if [ -n "$info_line" ]; then
  output="${output}${newline}${info_line}"
fi
if [ -n "$org_line" ]; then
  output="${output}${newline}${org_line}"
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

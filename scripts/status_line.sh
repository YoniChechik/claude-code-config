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
# `sort -t` and `awk -F` agree on it. NOT usable with `read`: bash collapses a
# RUN of IFS-whitespace delimiters (space, tab, newline) into one, so an empty
# field between two tabs would silently disappear and shift every field after
# it. Anything `read` has to split uses $us instead.
tab=$'\t'
# ASCII Unit Separator: a non-whitespace IFS, so `read` treats every occurrence
# as its own delimiter and preserves empty fields.
us=$'\037'

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
#
# Two render caps keep this bounded. Nothing on disk is ever pruned (the
# watchers are the only writers and they must never read-modify-write a shared
# file), so the BOUNDS LIVE HERE:
#   * MAX_TERMINAL_ROWS — a watcher that reached a terminal state keeps its
#     state file forever, so without a cap a long session grows one permanent
#     row per branch it ever watched. Live watchers are never dropped; only the
#     oldest terminal rows are, ordered by state-file mtime.
#   * MAX_FINISHED_LINES / MAX_FINISHED_PRS — the finished-PR file is
#     append-only and never deleted, so both the parse cost and the row width
#     would otherwise grow with the length of the session.
MAX_TERMINAL_ROWS=5
MAX_FINISHED_LINES=200
MAX_FINISHED_PRS=10

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

# Render ONE watcher's row from its slot ($1). Echoes "<kind><TAB><row>", where
# kind is "active" (a watcher is still expected to update this row) or
# "terminal" (nothing will ever change it again, so the caller may cap it away).
# Echoes nothing at all when the row must be hidden.
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
  # ONE jq for every field, not one per field: this runs per watcher on a
  # ~1/second poll, and each extra call is its own fork+exec. The fields are
  # joined on $us and every separator/newline inside a value is replaced first,
  # so the split below cannot be confused by the record's own content.
  local pr_fields="" pr_url="" pr_number="" repo_url="" merge_oid="" merge_state="" pr_part=""
  if [ -f "$pr_cache_file" ]; then
    pr_fields=$(jq -r '
      [(.url // ""), (.number // ""), (.repoUrl // ""),
       (.mergeCommit.oid // ""), (.mergeStateStatus // "")]
      | map(tostring | gsub("[\u001f\n\t]"; " ")) | join("\u001f")' \
      "$pr_cache_file" 2>/dev/null || true)
    IFS="$us" read -r pr_url pr_number repo_url merge_oid merge_state <<< "$pr_fields" || true
  fi
  if [ -n "$pr_url" ] && [ "$pr_url" != "null" ] \
     && [ -n "$pr_number" ] && [ "$pr_number" != "null" ]; then
    # OSC 8 hyperlink, with the escapes already expanded (see the color note at
    # the top) so the render stage never has to interpret backslashes.
    pr_part=$'\033]8;;'"${pr_url}"$'\a'"PR #${pr_number}"$'\033]8;;\a'
  fi

  # Terminal states are the watcher's DOCUMENTED exits (see the ci-watcher
  # SKILL.md): no watcher is expected any more, so the result is shown as-is,
  # never as a death. For every other state this slot's OWN lockfile decides
  # whether the watcher is still alive.
  local alive=false kind=active pid
  case "$state_only" in
    # ci_watch.py EXITS on these and deliberately keeps its state file, so the
    # row is final and the cap above may drop it once it is old enough.
    merged-failed|timeout|no-main-ci|no-ci-configured|closed)
      alive=true
      kind=terminal
      ;;
    # Reported results the watcher keeps polling past (it waits for the merge),
    # so no "died" label — but the row is still live and never capped away.
    passed|failed|no-ci)
      alive=true
      ;;
    *)
      # First line only, and a regular file only: acquire_lock writes the pid at
      # offset 0 then truncates, and a FIFO planted here would block `cat`.
      if [ -f "$lock_file" ]; then
        pid=$(head -n 1 "$lock_file" 2>/dev/null || true)
      else
        pid=""
      fi
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
         && ps -p "$pid" -o args= 2>/dev/null | grep -q "ci_watch"; then
        alive=true
      fi
      ;;
  esac

  local ci_display="" ci_state
  if [ "$alive" = false ] && [ -n "$state_only" ]; then
    # The watcher should still be running but is gone — a crash, not an exit.
    ci_display="${red}⚠ ci watcher died${reset}"
    kind=terminal
  elif [ "$detached" = true ]; then
    # Alive, but mute: distinct from both "died" and a plain running state.
    ci_display="${red}⚠ ci notifications lost — restart watcher${reset}"
  else
    ci_state="$state_only"
    if [ "$ci_state" = "passed" ]; then
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
      # The PR was closed without a merge. That is a DOCUMENTED watcher exit,
      # not a crash, so it must never render as "ci watcher died".
      closed)        ci_display="${yellow}pr: closed${reset}" ;;
      stuck-pending) ci_display="${yellow}⚠ checks stuck pending${reset}" ;;
      # Post-merge states carry a "post merge" label instead of "ci", linked to
      # GitHub's check list for the merge commit.
      merging)       ci_display="${yellow}$(post_merge_label "$repo_url" "$merge_oid"): running${reset}" ;;
      merged-failed) ci_display="${red}$(post_merge_label "$repo_url" "$merge_oid"): failed${reset}" ;;
      *)             ci_display="" ;;
    esac
  fi

  local row=""
  if [ -n "$ci_display" ] && [ -n "$pr_part" ]; then
    row="${pr_part} | ${ci_display}"
  elif [ -n "$ci_display" ]; then
    row="$ci_display"
  elif [ -n "$pr_part" ]; then
    row="$pr_part"
  fi
  [ -n "$row" ] || return 0
  printf '%s%s%s' "$kind" "$tab" "$row"
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

  # ONE jq for the whole file, not one per line: this file is append-only and
  # never pruned, so a per-line fork would grow with the length of the session
  # on a ~1/second poll. `fromjson?` drops an unparseable line INSIDE jq, which
  # keeps the same tolerance for a torn write from a killed watcher. Only the
  # last MAX_FINISHED_LINES are read, so the parse cost is bounded too. @tsv
  # escapes any tab or newline inside a value, so the split below cannot be
  # confused by the record's own content.
  local entries
  entries=$(tail -n "$MAX_FINISHED_LINES" "$file" 2>/dev/null | jq -R -r '
    fromjson?
    | select(type == "object")
    | select((.number | type) == "number")
    | select((.repo | type) == "string" and .repo != "")
    | select((.ts | type) == "number")
    | select((.url | type) == "string")
    | [.ts, .number, .repo, .url] | @tsv' 2>/dev/null || true)
  [ -n "$entries" ] || return 0

  # Dedupe on (repo, number), NEVER on the number alone: PR numbers are
  # repo-local and one session watches branches across several repos, so #42 in
  # two repos are two different PRs. The duplicate this drops is the relaunch
  # case — the same watcher finishing the same PR twice — and the newest ts
  # wins. Then order newest first, with the PR number as a tiebreak so two
  # entries written in the same clock tick still have a defined order.
  local sorted
  sorted=$(printf '%s\n' "$entries" \
    | sort -t"$tab" -k3,3 -k2,2n -k1,1nr \
    | awk -F"$tab" '!seen[$3 SUBSEP $2]++' \
    | sort -t"$tab" -k1,1nr -k2,2n \
    | head -n "$MAX_FINISHED_PRS" || true)
  [ -n "$sorted" ] || return 0

  # ts, number and repo are all guaranteed non-empty by the jq filter above, and
  # the url is LAST, so bash's collapsing of consecutive tabs cannot shift a
  # value into the wrong variable here — an empty url simply reads back empty.
  local out="" number url link
  while IFS="$tab" read -r _ number _ url; do
    [ -n "$number" ] || continue
    if [ -n "$url" ]; then
      link=$'\033]8;;'"${url}"$'\a'"#${number}"$'\033]8;;\a'
    else
      # The PR fetch failed on the iteration that recorded this entry, so there
      # is no target. An OSC 8 link to an empty url is worse than plain text.
      link="#${number}"
    fi
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
  _state_files=()
  while IFS= read -r _state_file; do
    [ -n "$_state_file" ] || continue
    _state_files+=("$_state_file")
  done < <(_ci_watch_session_state_files "$session_id")

  # One `ls -t` fork orders every slot by state-file mtime, newest first, so the
  # most recently active watcher renders at the top and the MAX_TERMINAL_ROWS
  # cap below drops the OLDEST finished rows. Slot names hold only a UUID and
  # [A-Za-z0-9._-], so no name can contain a newline and break this loop.
  _ordered=()
  if [ "${#_state_files[@]}" -gt 0 ]; then
    while IFS= read -r _state_file; do
      [ -n "$_state_file" ] || continue
      _ordered+=("$_state_file")
    done < <(ls -t "${_state_files[@]}" 2>/dev/null || printf '%s\n' "${_state_files[@]}")
  fi

  # Live rows always render; terminal rows are capped, so a long session cannot
  # accumulate one permanent row per branch it ever watched.
  _active_rows=()
  _terminal_rows=()
  for _state_file in ${_ordered[@]+"${_ordered[@]}"}; do
    _out=$(render_ci_row "${_state_file##*/ci_watch_state_}")
    [ -n "$_out" ] || continue
    _kind="${_out%%"$tab"*}"
    _row="${_out#*"$tab"}"
    if [ "$_kind" = "terminal" ]; then
      if [ "${#_terminal_rows[@]}" -lt "$MAX_TERMINAL_ROWS" ]; then
        _terminal_rows+=("$_row")
      fi
    else
      _active_rows+=("$_row")
    fi
  done
  for _row in ${_active_rows[@]+"${_active_rows[@]}"}; do
    pr_lines+=("$_row")
  done
  for _row in ${_terminal_rows[@]+"${_terminal_rows[@]}"}; do
    pr_lines+=("$_row")
  done

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

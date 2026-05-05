#!/usr/bin/env bash
# Unified startup hook: env validation, git sync, clone cleanup.
# Outputs a single JSON systemMessage line. Always exits 0.

# ── Session identity ──────────────────────────────────────────────────────────
# Read the hook payload (session_start.sh receives JSON on stdin).
# We must consume stdin exactly once, early, before anything else reads it.
INPUT=$(cat)

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null || true)
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // ""' 2>/dev/null || true)
SID8=""
if [[ -n "$SESSION_ID" && "$SESSION_ID" != "null" ]]; then
    SID8="${SESSION_ID:0:8}"
fi

if [[ -n "$SID8" ]]; then
    mkdir -p "$HOME/.claude/session-env/$SESSION_ID" "$HOME/.claude/cache/ppid-session"

    # Atomic writes: mktemp + mv so readers never see partial content.

    # session-env: keyed by full session_id (debugging / future hooks).
    _tmp=$(mktemp "$HOME/.claude/session-env/$SESSION_ID/sid8.XXXXXX")
    printf '%s' "$SID8" > "$_tmp"
    mv -f "$_tmp" "$HOME/.claude/session-env/$SESSION_ID/sid8"

    # ppid-session: keyed by Claude Code's PID. $PPID inside a hook = the
    # Claude process that spawned the hook. This is stable across all `cd`
    # operations (e.g. /new-feature cd'ing into a clone), so it's the
    # canonical lookup path for any consumer that doesn't have the hook
    # payload itself (the /ci skill, sid8_from_ppid() helpers).
    _ppid_tmp=$(mktemp "$HOME/.claude/cache/ppid-session/$PPID.XXXXXX")
    printf '%s' "$SID8" > "$_ppid_tmp"
    mv -f "$_ppid_tmp" "$HOME/.claude/cache/ppid-session/$PPID"
else
    # Log so we can detect harness changes.
    mkdir -p "$HOME/.claude/logs"
    printf '[%s] session_start.sh: no session_id in payload\n' "$(date -u +%FT%TZ)" >> "$HOME/.claude/logs/session_start.log"
    INPUT_DBG=$(printf '%s' "$INPUT" | head -c 500)
    printf '  payload preview: %s\n' "$INPUT_DBG" >> "$HOME/.claude/logs/session_start.log"
fi
# ─────────────────────────────────────────────────────────────────────────────

output=""
add_line() { output+="$1"$'\n'; }

# --- Environment validation ---
env_issues=()

if ! command -v jq &>/dev/null; then
    env_issues+=("jq is not installed")
fi

git_root=$(git rev-parse --show-toplevel 2>/dev/null) || true
if [[ -z "$git_root" ]]; then
    env_issues+=("not a git repository")
fi

if [[ ${#env_issues[@]} -gt 0 ]]; then
    add_line "Environment issues:"
    for issue in "${env_issues[@]}"; do
        add_line "  - $issue"
    done
else
    add_line "Environment: OK"
fi

# If not a git repo or jq missing, skip git operations
if [[ -z "$git_root" ]] || ! command -v jq &>/dev/null; then
    printf '%s\n' "{\"systemMessage\": $(printf '%s' "$output" | jq -Rs .)}"
    exit 0
fi

# --- Single fetch with prune ---
fetch_output=$(git fetch -p 2>&1) || true

# --- Git merge --ff-only (using already-fetched data) ---
current_branch=$(git branch --show-current 2>/dev/null)
if [[ -n "$current_branch" ]]; then
    if ! git rev-parse --verify "origin/$current_branch" &>/dev/null; then
        add_line "Git: up to date"
    else
        merge_output=$(git merge --ff-only "origin/$current_branch" 2>&1)
        merge_exit=$?

        if [[ $merge_exit -eq 0 ]]; then
            if echo "$merge_output" | grep -q "Already up to date"; then
                add_line "Git: up to date"
            else
                add_line "Git: merged"
            fi
        else
            error_msg=$(echo "$merge_output" | head -1)
            add_line "Git: error: $error_msg"
        fi
    fi
else
    add_line "Git: no current branch (detached HEAD)"
fi

# --- Clone cleanup ---
clones_dir="${git_root}/_clones"
removed_clones=()
existing_clones=()

if [[ -d "$clones_dir" ]]; then
    for clone_dir in "${clones_dir}"/*; do
        [[ ! -d "$clone_dir" ]] && continue
        [[ ! -d "$clone_dir/.git" ]] && continue

        branch=$(git -C "$clone_dir" branch --show-current 2>/dev/null)
        [[ -z "$branch" ]] && continue

        dir_name=$(basename "$clone_dir")

        if [[ $branch == "main" || $branch == "master" ]]; then
            existing_clones+=("$dir_name")
            continue
        fi

        if git ls-remote --heads origin "$branch" 2>/dev/null | grep -qF "refs/heads/$branch"; then
            existing_clones+=("$dir_name")
            continue
        fi

        if rm -rf "$clone_dir" 2>/dev/null; then
            removed_clones+=("$dir_name")
        fi
    done
fi

# Clean local branches with gone tracking
removed_branches=()
while read -r line; do
    [[ $line =~ ^[*+] ]] && continue
    branch=$(echo "$line" | awk '{print $1}')
    [[ $branch == "main" || $branch == "master" ]] && continue
    echo "$line" | grep -q ': gone]' || continue
    if git branch -D "$branch" 2>/dev/null; then
        removed_branches+=("$branch")
    fi
done < <(git branch -vv)

# Output clones section only if there's something to report
if [[ ${#existing_clones[@]} -gt 0 || ${#removed_clones[@]} -gt 0 || ${#removed_branches[@]} -gt 0 ]]; then
    add_line "Clones:"
    for clone in "${existing_clones[@]}"; do
        add_line "  Existing: $clone"
    done
    for clone in "${removed_clones[@]}"; do
        add_line "  Removed: $clone"
    done
    for branch in "${removed_branches[@]}"; do
        add_line "  Removed branch: $branch"
    done
fi

# --- Resume detection ---
if [[ "$SOURCE" == "resume" ]]; then
    add_line ""
    add_line "RESUME DETECTED: Immediately invoke /continue-feature to restore working context for the active feature branch."
fi

# --- Output JSON systemMessage ---
printf '%s\n' "{\"systemMessage\": $(printf '%s' "$output" | jq -Rs .)}"
exit 0

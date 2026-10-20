#!/usr/bin/env bash

: "${HOOK_NAME:=git_sync}"
source "$(dirname "${BASH_SOURCE[0]}")/_hook_log.sh"

_sync_primary_checkout_to_origin_main() {
    local dir="$1"
    if git -C "$dir" checkout -f main >/dev/null 2>&1 \
        && [[ "$(git -C "$dir" branch --show-current 2>/dev/null)" == "main" ]]; then
        git -C "$dir" fetch origin --prune >/dev/null 2>&1 || true
        git -C "$dir" reset --hard origin/main >/dev/null 2>&1 || true
        git -C "$dir" clean -fd >/dev/null 2>&1 || true
    fi
}

_wt_regex_escape() {
    printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'
}

_wt_path_in_text() {
    local path="$1" text="$2" esc
    esc=$(_wt_regex_escape "$path")
    grep -qE -- "${esc}(/|[[:space:]]|\$)" <<<"$text"
}

_wt_snapshot_processes() {
    WT_PS_TEXT=$(ps -axo command= 2>/dev/null)
    WT_CWD_TEXT=$(lsof -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
}

_wt_in_use() {
    local path="$1"
    _wt_path_in_text "$path" "$WT_PS_TEXT" && return 0
    _wt_path_in_text "$path" "$WT_CWD_TEXT" && return 0
    return 1
}

_wt_lock_pid_alive() {
    local reason="$1" pid
    [[ "$reason" =~ \(pid\ ([0-9]+)\) ]] || return 1
    pid="${BASH_REMATCH[1]}"
    kill -0 "$pid" 2>/dev/null
}

_wt_remove() {
    local git_root="$1" path="$2" locked="$3" reason="$4" out
    if [[ "$locked" == "1" ]]; then
        if _wt_lock_pid_alive "$reason" || _wt_in_use "$path"; then
            hook_log "keep: locked worktree held by a live process ($reason)" "$path"
            return 1
        fi
        out=$(git -C "$git_root" worktree unlock "$path" 2>&1) \
            || hook_log "unlock failed: $out" "$path"
    elif _wt_in_use "$path"; then
        hook_log "keep: live process inside worktree" "$path"
        return 1
    fi
    if out=$(git -C "$git_root" worktree remove --force --force "$path" 2>&1); then
        hook_log "removed worktree" "$path"
        return 0
    fi
    hook_log "remove failed: $out" "$path"
    return 1
}

_wt_last_touched() {
    local path="$1" last_commit last_touched status f _orig m entry
    last_commit=$(git -C "$path" log -1 --format=%ct 2>/dev/null)
    last_touched="${last_commit:-0}"
    while IFS= read -r -d '' entry; do
        status="${entry:0:2}"
        f="${entry:3}"
        if [[ "$status" == *R* || "$status" == *C* ]]; then
            IFS= read -r -d '' _orig
        fi
        [[ -z "$f" ]] && continue
        m=$(stat -f "%m" "${path}/${f}" 2>/dev/null) || continue
        (( m > last_touched )) && last_touched="$m"
    done < <(git -C "$path" status --porcelain -z 2>/dev/null)
    echo "$last_touched"
}

_wt_merged_or_abandoned() {
    local git_root="$1" path="$2" branch="$3" default_branch="$4"
    local local_sha remote_sha ahead_count pr_state
    local_sha=$(git -C "$git_root" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null) || return 1
    remote_sha=$(git -C "$git_root" ls-remote --heads origin "$branch" 2>/dev/null | awk -v r="refs/heads/$branch" '$2 == r {print $1; exit}')
    if [[ -n "$remote_sha" && "$remote_sha" != "$local_sha" ]]; then
        git -C "$git_root" merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null || return 1
    fi
    ahead_count=$(git -C "$git_root" rev-list --count "$default_branch".."$branch" 2>/dev/null || echo 0)
    if [[ "$ahead_count" != "0" ]] && git -C "$git_root" merge-base --is-ancestor "$branch" "$default_branch" 2>/dev/null; then
        return 0
    fi
    pr_state=$(cd "$git_root" && gh pr view "$branch" --json state -q .state 2>/dev/null) || true
    [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]]
}

_wt_detached_has_nothing_unique() {
    local git_root="$1" path="$2" default_branch="$3" base unique
    base="origin/$default_branch"
    git -C "$git_root" rev-parse --verify --quiet "$base" >/dev/null 2>&1 || base="$default_branch"
    unique=$(git -C "$path" cherry "$base" HEAD 2>/dev/null) || return 1
    [[ "$unique" != *"+"* ]]
}

_wt_sweep_one() {
    local git_root="$1" path="$2" branch="$3" detached="$4" locked="$5" reason="$6"
    local default_branch="$7" age_cutoff="$8" cwd_real="$9" last_touched

    [[ -z "$path" || "$path" == "$git_root" ]] && return 0
    [[ "$branch" == "main" || "$branch" == "master" ]] && return 0
    [[ "$cwd_real" == "$path" || "$cwd_real" == "$path"/* ]] && return 0

    if [[ ! -d "$path" ]]; then
        if [[ "$locked" == "1" ]] && ! _wt_lock_pid_alive "$reason"; then
            git -C "$git_root" worktree unlock "$path" >/dev/null 2>&1 \
                || hook_log "unlock of ghost entry failed" "$path"
        fi
        return 0
    fi

    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
        local broken_cutoff_str
        broken_cutoff_str=$(date -v-4d "+%Y-%m-%d %H:%M:%S")
        if find "$path" \( -name node_modules -o -name .next -o -name dist -o -name build -o -name .venv \) -prune -o -type f -newermt "$broken_cutoff_str" -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
        if [[ "$locked" == "1" ]]; then
            _wt_lock_pid_alive "$reason" && return 0
            git -C "$git_root" worktree unlock "$path" >/dev/null 2>&1 || true
        fi
        _wt_in_use "$path" && return 0
        rm -rf "$path" && hook_log "removed broken worktree" "$path"
        return 0
    fi

    [[ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]] && return 0

    if [[ -n "$branch" ]]; then
        if _wt_merged_or_abandoned "$git_root" "$path" "$branch" "$default_branch"; then
            _wt_remove "$git_root" "$path" "$locked" "$reason" || true
            return 0
        fi
    elif [[ "$detached" == "1" ]]; then
        if _wt_detached_has_nothing_unique "$git_root" "$path" "$default_branch"; then
            _wt_remove "$git_root" "$path" "$locked" "$reason" || true
            return 0
        fi
    else
        return 0
    fi

    last_touched=$(_wt_last_touched "$path")
    [[ "$last_touched" == "0" ]] && return 0
    (( last_touched > age_cutoff )) && return 0
    _wt_remove "$git_root" "$path" "$locked" "$reason" || true
    return 0
}

_wt_sweep_orphans() {
    local git_root="$1" cwd_real="$2" main_root common_dir registered d real now other_common
    common_dir=$(git -C "$git_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
    main_root="${common_dir%/.git}"
    [[ -d "$main_root/.claude/worktrees" ]] || return 0
    registered=$(git -C "$git_root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    now=$(date +%s)
    for d in "$main_root"/.claude/worktrees/*/; do
        [[ -d "$d" ]] || continue
        real=$(cd -P "$d" 2>/dev/null && pwd -P) || continue
        grep -qxF -- "$real" <<<"$registered" && continue
        grep -qxF -- "${d%/}" <<<"$registered" && continue
        [[ "$cwd_real" == "$real" || "$cwd_real" == "$real"/* ]] && continue
        if other_common=$(git -C "$real" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
            && [[ "$other_common" != "$common_dir" ]]; then
            continue
        fi
        (( now - $(stat -f %m "$real" 2>/dev/null || echo "$now") < 3600 )) && continue
        _wt_in_use "$real" && continue
        rm -rf "$real" && hook_log "removed orphan worktree directory" "$real"
    done
}

_cleanup_worktrees_and_branches() {
    local git_root="$1"
    [[ -n "$git_root" ]] || return 0

    local default_branch="main"
    git -C "$git_root" rev-parse --verify --quiet main >/dev/null 2>&1 || default_branch="master"

    local age_cutoff=$(( $(date +%s) - 4*24*60*60 ))
    local cwd_real
    cwd_real=$(pwd -P)

    _wt_snapshot_processes

    local line wt_path="" wt_branch="" wt_detached=0 wt_locked=0 wt_reason=""
    local records=()
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) wt_path="${line#worktree }" ;;
            "branch refs/heads/"*) wt_branch="${line#branch refs/heads/}" ;;
            "detached") wt_detached=1 ;;
            "locked") wt_locked=1 ;;
            "locked "*) wt_locked=1; wt_reason="${line#locked }" ;;
            "")
                [[ -n "$wt_path" ]] && records+=("$wt_path"$'\x1f'"$wt_branch"$'\x1f'"$wt_detached"$'\x1f'"$wt_locked"$'\x1f'"$wt_reason")
                wt_path=""; wt_branch=""; wt_detached=0; wt_locked=0; wt_reason=""
                ;;
        esac
    done < <(git -C "$git_root" worktree list --porcelain 2>/dev/null; echo)

    local rec
    for rec in "${records[@]}"; do
        IFS=$'\x1f' read -r wt_path wt_branch wt_detached wt_locked wt_reason <<<"$rec"
        _wt_sweep_one "$git_root" "$wt_path" "$wt_branch" "$wt_detached" "$wt_locked" "$wt_reason" \
            "$default_branch" "$age_cutoff" "$cwd_real"
    done

    _wt_sweep_orphans "$git_root" "$cwd_real"

    git -C "$git_root" worktree prune 2>&1 | while IFS= read -r line; do hook_log "prune: $line" "$git_root"; done

    local branch
    while read -r line; do
        [[ $line =~ ^[*+] ]] && continue
        branch=$(echo "$line" | awk '{print $1}')
        [[ $branch == "main" || $branch == "master" ]] && continue
        echo "$line" | grep -q ': gone]' || continue
        git -C "$git_root" branch -D "$branch" 2>/dev/null || true
    done < <(git -C "$git_root" branch -vv)
}

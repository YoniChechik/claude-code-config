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

_wt_timeout() {
    local secs="$1" out rc pid watchdog
    shift
    out=$(mktemp "${TMPDIR:-/tmp}/wt-sweep.XXXXXX") || return 1
    (cd "$WT_GIT_ROOT" && exec "$@") >"$out" 2>/dev/null </dev/null &
    pid=$!
    (
        trap 'kill "$nap" 2>/dev/null; exit 0' TERM
        sleep "$secs" &
        nap=$!
        wait "$nap"
        kill "$pid" 2>/dev/null
    ) >/dev/null 2>&1 </dev/null &
    watchdog=$!
    wait "$pid"
    rc=$?
    kill "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    cat "$out"
    rm -f "$out"
    return "$rc"
}

_wt_snapshot_processes() {
    local lsof_out
    WT_SNAPSHOT_OK=1
    WT_PS_TEXT=$(ps -axo command= 2>/dev/null) || WT_SNAPSHOT_OK=0
    lsof_out=$(lsof -d cwd -Fn 2>/dev/null) || true
    WT_CWD_TEXT=$(sed -n 's/^n//p' <<<"$lsof_out")
    if [[ -z "$WT_PS_TEXT" || -z "$WT_CWD_TEXT" ]]; then
        WT_SNAPSHOT_OK=0
    fi
    if [[ "$WT_SNAPSHOT_OK" != "1" ]]; then
        hook_log "process snapshot failed (ps or lsof); treating every worktree as in use" ""
    fi
}

_wt_in_use() {
    local path="$1"
    [[ "$WT_SNAPSHOT_OK" == "1" ]] || return 0
    _wt_path_in_text "$path" "$WT_PS_TEXT" && return 0
    _wt_path_in_text "$path" "$WT_CWD_TEXT" && return 0
    return 1
}

_wt_resolve() {
    local path="$1" parent
    if [[ -d "$path" ]]; then
        (cd -P "$path" 2>/dev/null && pwd -P)
        return
    fi
    parent=$(cd -P "$(dirname "$path")" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$parent" "$(basename "$path")"
}

_wt_contained() {
    local path="$1" resolved
    resolved=$(_wt_resolve "$path") || return 1
    [[ "$resolved" == "$WT_DIR"/?* ]]
}

_wt_birth() {
    stat -f %B "$1" 2>/dev/null || echo 0
}

_wt_mtime() {
    stat -f %m "$1" 2>/dev/null || echo 0
}

_wt_settled() {
    local path="$1" mins cutoff recent admin f
    mins=$(( ${WORKTREE_SWEEP_IDLE_HOURS:-12} * 60 ))
    cutoff=$(( $(date +%s) - mins * 60 ))
    (( $(_wt_birth "$path") <= cutoff )) || return 1
    recent=$(find "$path" -maxdepth 4 -mmin -"$mins" -print -quit 2>/dev/null) || return 1
    [[ -z "$recent" ]] || return 1
    admin=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || return 0
    for f in "$admin/HEAD" "$admin/logs/HEAD" "$admin/ORIG_HEAD"; do
        (( $(_wt_mtime "$f") <= cutoff )) || return 1
    done
    return 0
}

_wt_has_unpushed() {
    local path="$1" n
    n=$(git -C "$path" rev-list --count HEAD --not --remotes 2>/dev/null) || return 0
    [[ "$n" != "0" ]]
}

_wt_lock_pid_alive() {
    local reason="$1" pid
    [[ "$reason" =~ \(pid\ ([0-9]+)\) ]] || return 1
    pid="${BASH_REMATCH[1]}"
    kill -0 "$pid" 2>/dev/null
}

_wt_unlock() {
    local git_root="$1" path="$2" out
    out=$(git -C "$git_root" worktree unlock "$path" 2>&1) || {
        hook_log "unlock failed: $out" "$path"
        return 1
    }
}

_wt_remove() {
    local git_root="$1" path="$2" locked="$3" reason="$4" out
    if ! _wt_contained "$path"; then
        hook_log "refused: path is not strictly under $WT_DIR" "$path"
        return 1
    fi
    if [[ "$locked" == "1" ]]; then
        if _wt_lock_pid_alive "$reason" || _wt_in_use "$path"; then
            hook_log "keep: locked worktree held by a live process ($reason)" "$path"
            return 1
        fi
        _wt_unlock "$git_root" "$path" || true
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
    local path="$1" last_commit last_touched status f _orig m entry birth
    last_commit=$(git -C "$path" log -1 --format=%ct 2>/dev/null)
    last_touched="${last_commit:-0}"
    birth=$(_wt_birth "$path")
    (( birth > last_touched )) && last_touched="$birth"
    while IFS= read -r -d '' entry; do
        status="${entry:0:2}"
        f="${entry:3}"
        if [[ "$status" == *R* || "$status" == *C* ]]; then
            IFS= read -r -d '' _orig
        fi
        [[ -z "$f" ]] && continue
        m=$(stat -f "%m" "${path}/${f}" 2>/dev/null) || continue
        (( m > last_touched )) && last_touched="$m"
    done < <(git -C "$path" --no-optional-locks status --porcelain -z 2>/dev/null)
    echo "$last_touched"
}

_wt_merged_or_abandoned() {
    local git_root="$1" branch="$2" default_branch="$3"
    local local_sha remote_sha remote_out base pr_out pr_state pr_head
    local_sha=$(git -C "$git_root" rev-parse --verify --quiet "refs/heads/$branch" 2>/dev/null) || return 1
    remote_out=$(_wt_timeout "${WT_NET_TIMEOUT:-20}" git -C "$git_root" ls-remote --heads origin "$branch") || return 1
    remote_sha=$(awk -v r="refs/heads/$branch" '$2 == r {print $1; exit}' <<<"$remote_out")
    if [[ -n "$remote_sha" && "$remote_sha" != "$local_sha" ]]; then
        git -C "$git_root" merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null || return 1
    fi
    base="origin/$default_branch"
    git -C "$git_root" rev-parse --verify --quiet "$base" >/dev/null 2>&1 || base="$default_branch"
    if [[ "$(git -C "$git_root" rev-list --count "$base".."$branch" 2>/dev/null)" != "0" ]] \
        && git -C "$git_root" merge-base --is-ancestor "$branch" "$base" 2>/dev/null; then
        return 0
    fi
    pr_out=$(_wt_timeout "${WT_NET_TIMEOUT:-20}" gh pr view "$branch" --json state,headRefOid -q '.state + " " + .headRefOid') || return 1
    pr_state=${pr_out%% *}
    pr_head=${pr_out#* }
    [[ "$pr_state" == "MERGED" || "$pr_state" == "CLOSED" ]] || return 1
    [[ "$pr_head" =~ ^[0-9a-f]{40}$ ]] || return 1
    if ! git -C "$git_root" merge-base --is-ancestor "$local_sha" "$pr_head" 2>/dev/null; then
        hook_log "keep: branch has commits beyond the head of its $pr_state PR" "$branch"
        return 1
    fi
    return 0
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
    local default_branch="$7" age_cutoff="$8" cwd_real="$9" last_touched real

    [[ -z "$path" || "$path" == "$git_root" || "$path" == "$WT_MAIN_ROOT" ]] && return 0
    [[ "$branch" == "main" || "$branch" == "master" ]] && return 0
    if [[ -L "$path" ]]; then
        hook_log "skip: worktree path is a symlink" "$path"
        return 0
    fi
    if ! _wt_contained "$path"; then
        hook_log "skip: path is not strictly under $WT_DIR" "$path"
        return 0
    fi
    real=$(_wt_resolve "$path")
    [[ "$cwd_real" == "$real" || "$cwd_real" == "$real"/* ]] && return 0

    if [[ ! -d "$path" ]]; then
        if [[ "$locked" == "1" ]] && ! _wt_lock_pid_alive "$reason"; then
            _wt_unlock "$git_root" "$path" || true
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
            _wt_unlock "$git_root" "$path" || true
        fi
        _wt_in_use "$path" && return 0
        rm -rf "$real" && hook_log "removed broken worktree" "$real"
        return 0
    fi

    [[ -n "$(git -C "$path" --no-optional-locks status --porcelain 2>/dev/null)" ]] && return 0
    _wt_settled "$path" || return 0

    if [[ -n "$branch" ]]; then
        if _wt_merged_or_abandoned "$git_root" "$branch" "$default_branch"; then
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

    _wt_has_unpushed "$path" && return 0
    last_touched=$(_wt_last_touched "$path")
    [[ "$last_touched" == "0" ]] && return 0
    (( last_touched > age_cutoff )) && return 0
    _wt_remove "$git_root" "$path" "$locked" "$reason" || true
    return 0
}

_wt_sweep_orphans() {
    local git_root="$1" cwd_real="$2" registered d real recent
    registered=$(git -C "$git_root" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
    for d in "$WT_DIR"/*; do
        if [[ -L "$d" ]]; then
            hook_log "skip orphan: symlink" "$d"
            continue
        fi
        [[ -d "$d" ]] || continue
        real=$(cd -P "$d" 2>/dev/null && pwd -P) || continue
        _wt_contained "$real" || { hook_log "skip orphan: resolves outside $WT_DIR" "$d"; continue; }
        grep -qxF -- "$real" <<<"$registered" && continue
        grep -qxF -- "$d" <<<"$registered" && continue
        [[ "$cwd_real" == "$real" || "$cwd_real" == "$real"/* ]] && continue
        if [[ -e "$real/.git" ]]; then
            hook_log "keep orphan: has a git pointer that is not a registered worktree" "$real"
            continue
        fi
        if ! recent=$(find "$real" -maxdepth 4 -mmin -60 -print -quit 2>/dev/null) || [[ -n "$recent" ]]; then
            continue
        fi
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
    local cwd_real="${2:-}"
    [[ -n "$cwd_real" ]] || cwd_real=$(pwd -P)

    WT_GIT_ROOT="$git_root"
    local common_dir
    common_dir=$(git -C "$git_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common_dir=""
    WT_MAIN_ROOT=""
    WT_DIR=""
    if [[ "$common_dir" == */.git && -d "${common_dir%/.git}/.claude/worktrees" ]]; then
        WT_MAIN_ROOT=$(cd -P "${common_dir%/.git}" && pwd -P)
        WT_DIR="$WT_MAIN_ROOT/.claude/worktrees"
    fi

    local line wt_path="" wt_branch="" wt_detached=0 wt_locked=0 wt_reason="" rec
    if [[ -n "$WT_DIR" ]]; then
        _wt_snapshot_processes

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

        for rec in "${records[@]}"; do
            IFS=$'\x1f' read -r wt_path wt_branch wt_detached wt_locked wt_reason <<<"$rec"
            _wt_sweep_one "$git_root" "$wt_path" "$wt_branch" "$wt_detached" "$wt_locked" "$wt_reason" \
                "$default_branch" "$age_cutoff" "$cwd_real"
        done

        _wt_sweep_orphans "$git_root" "$cwd_real"
    fi

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

#!/usr/bin/env bash

BP_FILTER="${BASH_SOURCE[0]%/*}/bashparse.jq"
BP_TIMEOUT="${BASHPARSE_TIMEOUT:-3}"
BP_MAX_DEPTH="${BASHPARSE_DEPTH:-4}"
BP_READY=""
BP_JSON=""
BP_ERR=""
BP_RC=0
BP_TOOL=""
BP_CMD=""
BP_CWD=""
BP_FILE=""
BP_N=0
BP_F=()
BP_S=()
BP_NEST=()

_bp_watch() {
    local pid watchdog rc
    set -m
    "$@" &
    pid=$!
    set +m
    (
        sleep "$BP_TIMEOUT" &
        s=$!
        trap 'kill "$s" 2>/dev/null; exit 0' TERM
        wait "$s"
        kill -TERM -- -"$pid"
    ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid"
    rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    ((rc == 143)) && return 124
    return "$rc"
}

_bp_pipe() {
    local mode=$1 data=$2 rc cdpath=false
    [[ -n ${CDPATH:-} ]] && cdpath=true
    {
        if [[ $mode == hook ]]; then
            printf '%s\n' "$data"
            printf '%s' "$data" | jq -j '.tool_input.command | strings' 2>/dev/null | shfmt --to-json -ln bash
            rc=$?
            printf '\n{"bp_shfmt_rc":%d}\n' "$rc"
        elif [[ $mode == plain ]]; then
            printf '%s' "$data" | shfmt --to-json -ln bash
            rc=$?
            printf '\n{"bp_shfmt_rc":%d}\n' "$rc"
        else
            printf '%s\n' "$data"
        fi
    } | jq -n -j --arg mode "$mode" --arg cwd "$3" --arg known "$4" --arg pwd "$PWD" --arg home "$HOME" \
        --argjson cdpath "$cdpath" -f "$BP_FILTER"
}

_bp_stream() {
    local err rc
    { err=$({ _bp_watch _bp_pipe "$@" >&3; } 2>&1); rc=$?; } 3>&1
    printf '\0__BP__\0%s\0%s\0' "$rc" "$err"
}

_bp_run() {
    local n status msg
    mapfile -d '' BP_F < <(_bp_stream "$@")
    n=${#BP_F[@]}
    msg=${BP_F[n - 1]%%$'\n'*}
    if ((n < 4)) || [[ ${BP_F[n - 3]} != __BP__ ]]; then _BP_ERR="parser produced no status"; return 5; fi
    if [[ ${BP_F[n - 2]} == 124 ]]; then _BP_ERR="timeout: parse exceeded ${BP_TIMEOUT}s"; return 4; fi
    status=${BP_F[0]}
    if [[ ${BP_F[n - 2]} != 0 || $n -lt 11 || ${BP_F[n - 5]} != END || ${BP_F[n - 4]} != "" ]]; then
        if [[ $1 == hook ]] && ! printf '%s' "$2" | jq -e 'type == "object"' >/dev/null 2>&1; then
            _BP_ERR="bad hook input JSON"
            return 6
        fi
        _BP_ERR="jq failed: $msg"
        return 5
    fi
    case $status in
        ok) ;;
        parse) _BP_ERR="parse error: $msg"; return 2 ;;
        badinput) _BP_ERR="bad hook input JSON"; return 6 ;;
        *) _BP_ERR="jq failed: unexpected status"; return 5 ;;
    esac
    _BP_END=$((n - 5))
}

_bp_decode() {
    local p=6 i=0
    BP_S=()
    BP_NEST=()
    while ((p < _BP_END)); do
        BP_S[i]=$p
        bp_seg "$i"
        [[ -n $SEG_CODE ]] && BP_NEST+=("$i")
        p=$BP_NEXT
        i=$((i + 1))
    done
    BP_N=$i
}

_bp_level() {
    local rc
    _bp_run "$@"
    rc=$?
    if [[ $1 == hook && (${BP_F[0]} == ok || ${BP_F[0]} == parse) ]]; then
        BP_TOOL=${BP_F[1]}
        BP_CMD=${BP_F[2]}
        BP_CWD=${BP_F[3]}
        BP_FILE=${BP_F[4]}
        HOOK_LOG_CMD=$BP_CMD
    fi
    ((rc == 0)) || return "$rc"
    _bp_decode
    ((${#BP_NEST[@]} == 0)) && return 0
    _bp_nest "$5"
}

_bp_child() {
    local -a BP_F=() BP_S=() BP_NEST=()
    local _BP_END BP_N
    _bp_level plain "$@" || return
    _BP_CHILD=${BP_F[5]}
}

_bp_nest() {
    local depth=$1 parent=${BP_F[5]} k id rc nested="" fails=""
    local -a ids=("${BP_NEST[@]}") texts=() cwds=() knowns=()
    for id in "${ids[@]}"; do
        bp_seg "$id"
        texts+=("$SEG_CODE")
        cwds+=("$SEG_CWD")
        if ((SEG_CWD_KNOWN)); then knowns+=(true); else knowns+=(false); fi
    done
    for k in "${!ids[@]}"; do
        if ((depth <= 0)); then
            fails+="${fails:+,}\"${ids[k]}\":\"depth limit\""
            continue
        fi
        _bp_child "${texts[k]}" "${cwds[k]}" "${knowns[k]}" $((depth - 1))
        rc=$?
        if ((rc == 0)); then
            nested+="${nested:+,}\"${ids[k]}\":$_BP_CHILD"
        elif ((rc == 2)); then
            fails+="${fails:+,}\"${ids[k]}\":\"nested parse error\""
        else
            return "$rc"
        fi
    done
    _bp_run splice "$parent"$'\n'"{$nested}"$'\n'"{$fails}" "" false || return
    _bp_decode
}

bp_parse() {
    BP_JSON=""
    BP_ERR=""
    BP_N=0
    if ! command -v shfmt >/dev/null 2>&1; then BP_ERR="shfmt not installed"; return 3; fi
    if ! command -v jq >/dev/null 2>&1; then BP_ERR="jq not installed"; return 5; fi
    local cwd=${2:-$PWD} known=true rc
    [[ $cwd == /* ]] || known=false
    _bp_level plain "$1" "$cwd" "$known" "$BP_MAX_DEPTH"
    rc=$?
    if ((rc != 0)); then BP_ERR=$_BP_ERR; BP_N=0; return "$rc"; fi
    BP_JSON=${BP_F[5]}
}

bp_parse_hook() {
    BP_JSON=""
    BP_ERR=""
    BP_TOOL=""
    BP_CMD=""
    BP_CWD=""
    BP_FILE=""
    BP_N=0
    if ! command -v shfmt >/dev/null 2>&1; then BP_ERR="shfmt not installed"; return 3; fi
    if ! command -v jq >/dev/null 2>&1; then BP_ERR="jq not installed"; return 5; fi
    local rc
    _bp_level hook "$1" "$PWD" true "$BP_MAX_DEPTH"
    rc=$?
    if ((rc != 0)); then BP_ERR=$_BP_ERR; BP_N=0; return "$rc"; fi
    BP_JSON=${BP_F[5]}
}

bp_hook_meta() {
    local -a f
    BP_ERR=""
    mapfile -d '' f < <(printf '%s' "$1" | jq -j 'if type != "object" then error("not an object") else . end
        | (.tool_name // "" | tostring), "\u0000", (.cwd // "" | tostring), "\u0000",
          (.tool_input.file_path // .tool_input.notebook_path // "" | tostring), "\u0000"' 2>/dev/null)
    if ((${#f[@]} != 3)); then BP_ERR="bad hook input JSON"; return 6; fi
    BP_TOOL=${f[0]}
    BP_CWD=${f[1]}
    BP_FILE=${f[2]}
}

bp_hook_prepare() {
    [[ ${BP_READY:-} == 1 ]] && return "$BP_RC"
    BP_READY=1
    BP_N=0
    BP_TOOL=""
    case $1 in
        *'"tool_name":"Bash"'* | *'"tool_name": "Bash"'*) ;;
        *)
            bp_hook_meta "$1"
            BP_RC=$?
            [[ $BP_RC == 0 && $BP_TOOL != Bash ]] && return 0
            ((BP_RC != 0)) && return "$BP_RC"
            ;;
    esac
    bp_parse_hook "$1"
    BP_RC=$?
    return "$BP_RC"
}

bp_seg() {
    local p=${BP_S[$1]} n
    SEG_ID=${BP_F[p]}
    SEG_CMD=${BP_F[p + 1]}
    SEG_CWD=${BP_F[p + 2]}
    SEG_CWD_KNOWN=${BP_F[p + 3]}
    p=$((p + 4))
    n=${BP_F[p]}
    SEG_CWD_ALTS=("${BP_F[@]:p+1:n}")
    p=$((p + 1 + n))
    SEG_FLAGS=${BP_F[p]}
    SEG_VIA=${BP_F[p + 1]}
    SEG_CODE=${BP_F[p + 2]}
    SEG_DYN=${BP_F[p + 3]}
    p=$((p + 4))
    n=${BP_F[p]}
    SEG_ARGV=("${BP_F[@]:p+1:n}")
    p=$((p + 1 + n))
    n=${BP_F[p]}
    SEG_ENV=("${BP_F[@]:p+1:n}")
    p=$((p + 1 + n))
    n=${BP_F[p]}
    SEG_RAW=("${BP_F[@]:p+1:n}")
    p=$((p + 1 + n))
    n=${BP_F[p]}
    SEG_REASONS=("${BP_F[@]:p+1:n}")
    p=$((p + 1 + n))
    SEG_GIT=${BP_F[p]}
    p=$((p + 1))
    if ((SEG_GIT)); then
        SEG_GIT_SUB=${BP_F[p]}
        SEG_GIT_SUB_DYN=${BP_F[p + 1]}
        SEG_GIT_CWD=${BP_F[p + 2]}
        SEG_GIT_CWD_KNOWN=${BP_F[p + 3]}
        p=$((p + 4))
        n=${BP_F[p]}
        SEG_GIT_CWD_ALTS=("${BP_F[@]:p+1:n}")
        p=$((p + 1 + n))
        SEG_GIT_OVERRIDE=${BP_F[p]}
        p=$((p + 1))
        n=${BP_F[p]}
        SEG_GIT_ARGS=("${BP_F[@]:p+1:n}")
        p=$((p + 1 + n))
        n=${BP_F[p]}
        SEG_GIT_CONFIG=("${BP_F[@]:p+1:n}")
        p=$((p + 1 + n))
    else
        SEG_GIT_SUB=""
        SEG_GIT_SUB_DYN=0
        SEG_GIT_CWD=""
        SEG_GIT_CWD_KNOWN=0
        SEG_GIT_CWD_ALTS=()
        SEG_GIT_OVERRIDE=0
        SEG_GIT_ARGS=()
        SEG_GIT_CONFIG=()
    fi
    BP_NEXT=$p
}

bp_find() {
    local all=false i j ok
    if [[ ${1:-} == --all ]]; then all=true; shift; fi
    local -a w=("$@") have
    BP_MATCHES=()
    for ((i = 0; i < BP_N; i++)); do
        bp_seg "$i"
        if [[ $all == false && ($SEG_FLAGS == *X* || $SEG_FLAGS == *F*) ]]; then continue; fi
        if [[ ${w[0]} == git && $SEG_GIT == 1 ]]; then
            have=(git "$SEG_GIT_SUB" "${SEG_GIT_ARGS[@]}")
        elif [[ $SEG_CMD == "${w[0]}" ]]; then
            have=("$SEG_CMD" "${SEG_ARGV[@]:1}")
        else
            continue
        fi
        ((${#have[@]} >= ${#w[@]})) || continue
        ok=1
        for ((j = 1; j < ${#w[@]}; j++)); do
            [[ ${have[j]} == "${w[j]}" ]] || { ok=0; break; }
        done
        ((ok)) && BP_MATCHES+=("$i")
    done
    ((${#BP_MATCHES[@]} > 0))
}

bp_unknown() {
    local i r seen=$'\n'
    BP_UNKNOWN_REASONS=()
    for ((i = 0; i < BP_N; i++)); do
        bp_seg "$i"
        for r in "${SEG_REASONS[@]}"; do
            [[ $seen == *$'\n'"$r"$'\n'* ]] && continue
            seen+="$r"$'\n'
            BP_UNKNOWN_REASONS+=("$r")
        done
    done
    ((${#BP_UNKNOWN_REASONS[@]} > 0))
}

bp_segments_text() {
    local i line
    for ((i = 0; i < BP_N; i++)); do
        bp_seg "$i"
        printf -v line '%s ' "${SEG_CMD:-${SEG_ARGV[0]:-}}" "${SEG_ARGV[@]:1}"
        line=${line% }
        printf '%s\n' "${line//$'\n'/\\n}"
    done
}

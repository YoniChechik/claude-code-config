#!/usr/bin/env bash

BP_FILTER="${BASH_SOURCE[0]%/*}/bashparse.jq"
BP_TIMEOUT="${BASHPARSE_TIMEOUT:-3}"
BP_MAX_DEPTH="${BASHPARSE_DEPTH:-4}"
BP_JSON=""
BP_ERR=""
BP_CMD=""

_bp_timed() {
    local input=$1 pid watchdog rc
    shift
    "$@" <<<"$input" &
    pid=$!
    (
        sleep "$BP_TIMEOUT" &
        s=$!
        trap 'kill "$s" 2>/dev/null; exit 0' TERM
        wait "$s"
        kill -TERM "$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    watchdog=$!
    wait "$pid"
    rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    ((rc == 143)) && return 124
    return "$rc"
}

_bp_level() {
    local text=$1 cwd=$2 known=$3 depth=$4 ast flat rc cdpath=false
    [[ -n ${CDPATH:-} ]] && cdpath=true
    ast=$(_bp_timed "$text" shfmt --to-json -ln bash 2>&1)
    rc=$?
    if ((rc == 124)); then _BP_ERR="timeout: shfmt exceeded ${BP_TIMEOUT}s"; return 4; fi
    if ((rc != 0)); then _BP_ERR="parse error: ${ast%%$'\n'*}"; return 2; fi
    flat=$(_bp_timed "$ast" jq -c --arg cwd "$cwd" --argjson cwd_known "$known" --arg home "$HOME" \
        --argjson cdpath "$cdpath" -f "$BP_FILTER" 2>&1)
    rc=$?
    if ((rc == 124)); then _BP_ERR="timeout: jq exceeded ${BP_TIMEOUT}s"; return 4; fi
    if ((rc != 0)) || [[ $flat != \[* ]]; then _BP_ERR="jq failed: ${flat%%$'\n'*}"; return 5; fi
    if [[ $flat == *'"code":{"via"'* ]]; then
        _bp_nest "$flat" "$depth" || return
        flat=$_BP_OUT
    fi
    _BP_OUT=$flat
}

_bp_nest() {
    local flat=$1 depth=$2 k rc nested="" fails=""
    local -a items
    mapfile -d '' items < <(jq -j '.[] | select(.code != null)
        | (.id | tostring), "\u0000", .cwd, "\u0000", (.cwd_known | tostring), "\u0000", .code.text, "\u0000"' <<<"$flat")
    for ((k = 0; k + 3 < ${#items[@]}; k += 4)); do
        if ((depth <= 0)); then
            fails+="${fails:+,}\"${items[k]}\":\"depth limit\""
            continue
        fi
        _bp_level "${items[k + 3]}" "${items[k + 1]}" "${items[k + 2]}" $((depth - 1))
        rc=$?
        if ((rc == 0)); then
            nested+="${nested:+,}\"${items[k]}\":$_BP_OUT"
        elif ((rc == 2)); then
            fails+="${fails:+,}\"${items[k]}\":\"nested parse error\""
        else
            return "$rc"
        fi
    done
    _BP_OUT=$(jq -c --argjson n "{$nested}" --argjson f "{$fails}" '
        . as $p
        | reduce range(0; $p | length) as $i ([];
            ($i | tostring) as $key
            | ($p[$i] | if $f[$key] then .unknown = true | .unknown_reasons += [$f[$key]] else . end) as $seg
            | length as $ni
            | . + [$seg + {id: $ni}]
            | if $n[$key] then
                ($ni + 1) as $b
                | . + [$n[$key][]
                    | .id += $b
                    | .parent = (if .parent == null then $ni else .parent + $b end)
                    | .depth += $seg.depth + 1
                    | .via = (.via // $seg.code.via)
                    | .exit_code_belongs_to_command = (.exit_code_belongs_to_command and $seg.exit_code_belongs_to_command)
                    | .in_substitution = (.in_substitution or $seg.in_substitution)
                    | .in_function = (.in_function // $seg.in_function)
                    | .in_compound = (.in_compound // $seg.in_compound)
                    | .background = (.background or $seg.background)
                    | .negated = (.negated or $seg.negated)
                    | .in_subshell = (.in_subshell or $seg.in_subshell or $seg.code.via != "eval")
                    | .in_group = (.in_group or $seg.in_group)]
              else . end)' <<<"$flat") || { _BP_ERR="jq failed: nested splice"; return 5; }
}

bp_parse() {
    BP_JSON=""
    BP_ERR=""
    if ! command -v shfmt >/dev/null 2>&1; then BP_ERR="shfmt not installed"; return 3; fi
    if ! command -v jq >/dev/null 2>&1; then BP_ERR="jq not installed"; return 5; fi
    local cwd=${2:-$PWD} known=true rc
    [[ $cwd == /* ]] || known=false
    _bp_level "$1" "$cwd" "$known" "$BP_MAX_DEPTH"
    rc=$?
    if ((rc != 0)); then BP_ERR=$_BP_ERR; return "$rc"; fi
    BP_JSON=$_BP_OUT
}

bp_parse_hook() {
    local -a f
    BP_JSON=""
    BP_ERR=""
    BP_CMD=""
    mapfile -d '' f < <(jq -j '(.tool_input.command | if type == "string" then . else error("no command") end),
        "\u0000", (.cwd // "" | tostring), "\u0000"' <<<"$1" 2>/dev/null)
    if ((${#f[@]} != 2)); then BP_ERR="bad hook input JSON"; return 6; fi
    BP_CMD=${f[0]}
    HOOK_LOG_CMD=$BP_CMD
    bp_parse "$BP_CMD" "${f[1]:-$PWD}"
}

bp_count() {
    jq length <<<"$BP_JSON"
}

bp_find() {
    local all=false
    if [[ ${1:-} == --all ]]; then all=true; shift; fi
    mapfile -t BP_MATCHES < <(jq -r --argjson all "$all" '
        $ARGS.positional as $w
        | .[] | select($all or ((.in_substitution or .in_function != null) | not))
        | select(if $w[0] == "git" and .git != null then ([.git.sub] + .git.args)[0:($w | length) - 1] == $w[1:]
                 else .cmd == $w[0] and .argv[1:($w | length)] == $w[1:] end)
        | .id' --args "$@" <<<"$BP_JSON")
    ((${#BP_MATCHES[@]} > 0))
}

bp_get() {
    jq -r --argjson i "$1" ".[\$i] | $2" <<<"$BP_JSON"
}

bp_argv() {
    mapfile -d '' BP_ARGV < <(jq -j --argjson i "$1" '.[$i].argv[] | ., "\u0000"' <<<"$BP_JSON")
}

bp_git_sub() {
    local -a f
    mapfile -d '' f < <(jq -j --argjson i "$1" '.[$i].git // empty
        | (.sub // ""), "\u0000", .cwd, "\u0000", (.cwd_known | tostring), "\u0000", (.args[] | ., "\u0000")' <<<"$BP_JSON")
    ((${#f[@]} >= 3)) || return 1
    BP_GIT_SUB=${f[0]}
    BP_GIT_CWD=${f[1]}
    BP_GIT_CWD_KNOWN=${f[2]}
    BP_GIT_ARGS=("${f[@]:3}")
}

bp_unknown() {
    mapfile -t BP_UNKNOWN_REASONS < <(jq -r '[.[] | select(.unknown) | .unknown_reasons[]] | unique | .[]' <<<"$BP_JSON")
    ((${#BP_UNKNOWN_REASONS[@]} > 0))
}

bp_segments_text() {
    jq -r '.[] | [(.cmd // .argv[0] // "")] + .argv[1:] | join(" ") | gsub("\n"; "\\n")' <<<"$BP_JSON"
}

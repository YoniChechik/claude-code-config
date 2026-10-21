#!/bin/bash

GUARD_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && GUARD_DIR=${BASH_SOURCE[0]%/*}
GUARD_INTERNAL_ERROR_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"GUARD_INTERNAL_ERROR: the permission guard could not load scripts/_hook_log.sh or scripts/_bashparse.sh, so it is failing closed. Rewriting the command will not help: repair those guard libraries next to scripts/pre_tool_use__permission_guard.sh, or stop and tell the user they are missing or broken."}}'

if [[ ${BP_READY:-} != 1 ]] || ! declare -F bp_hook_prepare >/dev/null; then
    IFS= read -r -d '' INPUT
    if ! source "$GUARD_DIR/_hook_log.sh" 2>/dev/null || ! source "$GUARD_DIR/_bashparse.sh" 2>/dev/null; then
        printf '%s\n' "$GUARD_INTERNAL_ERROR_JSON"
        exit 0
    fi
    bp_hook_prepare "$INPUT"
fi
if ((BP_RC != 0)); then
    unparsed=$(printf '%s' "${INPUT:-}" | jq -r 'select(.tool_name == "Bash") | .tool_input.command // empty | strings' 2>/dev/null)
    unparsed_lc="${unparsed,,}"
    if [[ $unparsed_lc == *supabase* && $unparsed_lc == *query* ]]; then
        hook_log "deny: unparseable command mentioning supabase query (rc=$BP_RC)"
        hook_decision deny "Blocked: this command mentions \`supabase\` and \`query\` but the permission guard could not parse it, so it cannot prove the SQL is read-only. Split it into one plain command: \`supabase db query --linked 'begin read only; select ...; commit;'\` with the SQL as a single-quoted literal."
    fi
    exit 0
fi
STATE_ROOT_GUARD="${CLAUDE_STATE_DIR:-$HOME/.claude/state}"
DYN=$'\xef\xbf\xbd'
STATE_DENY_MSG="DENIED: ~/.claude/state holds the Stop gate's session ledger and its kill switch. Only the gate's own scripts write there (done_gate.sh predicate|check, the merge trigger, the post-merge watcher). Do not create, edit or delete these files: satisfy the gate instead (finish the work, start a real watcher, or end with \`STATUS: FAILURE <what>: <evidence>\`). The kill switch is for the user only."

normalize_path() {
    local part out=() parts
    IFS=/ read -ra parts <<<"$1"
    for part in "${parts[@]}"; do
        case "$part" in
            "" | .) ;;
            ..) ((${#out[@]})) && unset 'out[${#out[@]}-1]' ;;
            *) out+=("$part") ;;
        esac
    done
    local IFS=/
    REPLY="/${out[*]}"
}

state_path() {
    local p=$1 tilde='~'
    case "$p" in
        "$tilde"/*) p="$HOME/${p#"$tilde"/}" ;;
        "\$HOME/"*) p="$HOME/${p#\$HOME/}" ;;
        "\${HOME}/"*) p="$HOME/${p#\$\{HOME\}/}" ;;
        "\$/"*) p="$HOME/${p#\$/}" ;;
        "$DYN"/*) p="$HOME/${p#"$DYN"/}" ;;
    esac
    [[ $p == /* ]] || return 1
    normalize_path "$p"
    case "$REPLY" in
        "$STATE_ROOT_NORM" | "$STATE_ROOT_NORM"/*) return 0 ;;
    esac
    return 1
}

normalize_path "$STATE_ROOT_GUARD"
STATE_ROOT_NORM=$REPLY

if [[ $BP_TOOL == Write || $BP_TOOL == Edit || $BP_TOOL == NotebookEdit || $BP_TOOL == MultiEdit ]]; then
    if [ -n "$BP_FILE" ] && state_path "$BP_FILE"; then
        hook_log "deny: $BP_TOOL on gate state $BP_FILE"
        hook_decision deny "$STATE_DENY_MSG"
    fi
    exit 0
fi
[[ $BP_TOOL == Bash ]] || exit 0

SUPABASE_PROD_REFS=(pnseoblfzeqiczmmimnr ampdktckxcbdajezxkul)
PULUMI_PROD_STACK_NAMES=(production prod mirror main)

VERDICT_REASON=""

deny() { [ -n "$VERDICT_REASON" ] || VERDICT_REASON=$1; }

GH_DENY_MSG="Blocked: admin-required gh command. Admin actions (--admin flag, repo deletion, etc.) must be run manually by the user — do not retry. Ask the user to run it themselves."
GH_ADMIN_DENY_MSG="Blocked: \`--admin\` bypasses required checks. Run \`gh pr checks <n>\`, find the failing required check, fix its cause (a CVE: bump the dependency; a migration lint: fix the migration), push, and merge normally on green with \`gh pr merge <n> --squash --match-head-commit <sha>\`. Do not hand the merge to the user. If a required check cannot pass by design, end with \`STATUS: FAILURE admin-merge: <check> fails because <evidence>\`."
GCLOUD_PROJECT_DELETE_MSG="Blocked: \`gcloud projects delete\` deletes a whole Google Cloud project. It must be run manually by the user — do not retry."
GCLOUD_RUN_PROTECTED_PROJECTS='(production-490411|staging-480220|mirror-production-496017)'

has_prefix() {
    case "$1" in
        "$2"|"$2 "*) return 0 ;;
    esac
    return 1
}

env_get() {
    local e found=1
    REPLY=""
    for e in ${SEG_ENV[@]+"${SEG_ENV[@]}"}; do
        case "$e" in
            "$1="*) REPLY="${e#*=}"; found=0 ;;
        esac
    done
    if [ "$found" = "1" ] && [ -n "${!1+x}" ]; then
        REPLY="${!1}"
        found=0
    fi
    REPLY="${REPLY//$DYN/\$}"
    return "$found"
}

abs_dir() {
    local cwd="$1" dir="$2"
    REPLY=""
    if [[ "$dir" == /* ]]; then
        REPLY="$dir"
    elif [ -n "$cwd" ]; then
        REPLY="$cwd/$dir"
    fi
}

TOOL_ARGS=()
tool_args() {
    local name="$1" i=0 n=${#W[@]} tok
    TOOL_ARGS=()
    case "${W[0]:-}" in
        npx|pnpx|bunx|pnpm|yarn|npm)
            i=1
            while [ "$i" -lt "$n" ]; do
                tok="${W[$i]}"
                case "${tok,,}" in
                    "$name"|"$name"@*) break ;;
                    exec|dlx|x|--|-*) i=$((i + 1)) ;;
                    *) return 1 ;;
                esac
            done
            [ "$i" -lt "$n" ] || return 1
            ;;
        "$name") ;;
        *) return 1 ;;
    esac
    TOOL_ARGS=("${W[@]:i+1}")
    return 0
}

is_prod_supabase_ref() {
    local r
    for r in "${SUPABASE_PROD_REFS[@]}"; do
        [ "$1" = "$r" ] && return 0
    done
    return 1
}

text_has_prod_supabase_ref() {
    local r
    for r in "${SUPABASE_PROD_REFS[@]}"; do
        case "$1" in *"$r"*) return 0 ;; esac
    done
    return 1
}

supabase_find_ref_file() {
    local dir="$1" walk="$2"
    while :; do
        if [ -f "$dir/supabase/.temp/project-ref" ]; then
            REPLY="$dir/supabase/.temp/project-ref"
            return 0
        fi
        [ "$walk" = "1" ] || return 1
        [ "$dir" = "/" ] || [ -z "$dir" ] && return 1
        dir="${dir%/*}"
        [ -n "$dir" ] || dir="/"
    done
}

supabase_resolve_ref() {
    local flag_ref="$1" workdir="$2" cwd="$3" start walk=1 ref
    SB_REF=""
    if [ -n "$flag_ref" ]; then
        SB_REF="$flag_ref"
        return
    fi
    if env_get SUPABASE_PROJECT_ID && [ -n "$REPLY" ]; then
        SB_REF="$REPLY"
        return
    fi
    if [ -z "$workdir" ] && env_get SUPABASE_WORKDIR && [ -n "$REPLY" ]; then
        workdir="$REPLY"
    fi
    if [ -n "$workdir" ]; then
        abs_dir "$cwd" "$workdir"
        start="$REPLY"
        walk=0
    else
        start="$cwd"
    fi
    [ -n "$start" ] || return
    supabase_find_ref_file "$start" "$walk" || return
    ref=$(tr -d '[:space:]' <"$REPLY" 2>/dev/null)
    SB_REF="$ref"
}

supabase_remote_verdict() {
    local label="$1" flag_ref="$2" workdir="$3" cwd="$4"
    case "$flag_ref" in *'$'*) return ;; esac
    supabase_resolve_ref "$flag_ref" "$workdir" "$cwd"
    if [ -n "$SB_REF" ] && is_prod_supabase_ref "$SB_REF"; then
        deny "Blocked: \`$label\` targets the PRODUCTION Supabase project ($SB_REF). Production changes must be run manually by the user — do not retry."
    fi
}

supabase_db_url_verdict() {
    if text_has_prod_supabase_ref "$2"; then
        deny "Blocked: \`$1\` --db-url points at the PRODUCTION Supabase database. Production changes must be run manually by the user — do not retry."
    fi
}

SB_QUERY_LOCAL_URL_RE="^postgres(ql)?://([A-Za-z0-9._~%-]+(:[A-Za-z0-9._~%-]*)?@)?(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?(/[A-Za-z0-9_.-]*)?$"

sb_query_deny() {
    deny "Blocked: \`supabase db query\` against a remote Supabase database ($1) is allowed only as ONE read-only transaction passed as a single-quoted positional argument, e.g. \`supabase db query --linked 'begin read only; select ...; commit;'\` (\`start transaction read only;\` also works; \`set default_transaction_read_only = on;\` may come before the BEGIN but never replaces it). Rejected because: $2. Anything else is denied: -f files, stdin, heredocs, variables, command substitution, writes, DDL, SET/RESET, a second transaction, statements after the final COMMIT/ROLLBACK, side-effect functions. Retry in the allowed form; writes must be run manually by the user."
}

supabase_query_decide() {
    local cwd="$1" off="$2" n=${#TOOL_ARGS[@]} k=0 tok dyn remote=0 target="" problem="" out rc
    local -a pos=() posdyn=()
    while [ "$k" -lt "$n" ]; do
        tok="${TOOL_ARGS[$k]}"
        dyn="${SEG_DYN:off+k:1}"
        [ "$SBQ_FORCE_DYN" = "1" ] && dyn=1
        if [ "$dyn" = "1" ]; then
            remote=1
            target="${target:-a target that depends on a dynamic argument}"
            problem="${problem:-an argument is built from a variable, glob or command substitution}"
        fi
        case "$tok" in
            --) ;;
            --linked|--linked=*) remote=1; target="${target:-the --linked project}" ;;
            --local|--local=true) ;;
            --local=*) remote=1; target="${target:-$tok}" ;;
            --db-url|--db-url=*)
                if [ "$tok" = "--db-url" ]; then
                    k=$((k + 1)); tok="${TOOL_ARGS[$k]:-}"
                    dyn="${SEG_DYN:off+k:1}"
                    [ "$dyn" = "1" ] && problem="${problem:-the --db-url value is dynamic}"
                else
                    tok="${tok#*=}"
                fi
                if ! [[ $tok =~ $SB_QUERY_LOCAL_URL_RE ]] || [ "$dyn" = "1" ]; then
                    remote=1; target="a non-local --db-url"
                fi
                ;;
            -f|--file|-f?*|--file=*) problem="${problem:-SQL from a file (-f/--file) cannot be reviewed}" ;;
            -o|--output|--workdir|--profile|--network-id|--dns-resolver|--agent)
                k=$((k + 1))
                [ "${SEG_DYN:off+k:1}" = "1" ] && problem="${problem:-a flag value is dynamic}"
                ;;
            -o?*|--output=*|--workdir=*|--profile=*|--network-id=*|--dns-resolver=*|--agent=*) ;;
            --debug|--debug=*|--yes|--yes=*|--experimental|--experimental=*|--create-ticket|--create-ticket=*|-h|--help) ;;
            -*) remote=1; target="${target:-unknown flag $tok}"; problem="${problem:-unrecognised flag $tok}" ;;
            *) pos+=("$tok"); posdyn+=("$dyn") ;;
        esac
        k=$((k + 1))
    done
    local e
    for e in SUPABASE_DB_URL SUPABASE_LINKED SUPABASE_LOCAL; do
        if env_get "$e"; then
            remote=1; target="${target:-\$$e in the environment}"
        fi
    done
    { [ "${pos[0]:-}" = "db" ] || [ "${posdyn[0]:-}" = "1" ]; } || return 0
    { [ "${pos[1]:-}" = "query" ] || [ "${posdyn[1]:-}" = "1" ]; } || return 0
    [ "$remote" = "1" ] || return 0
    if [ "${posdyn[0]}${posdyn[1]}" != "00" ]; then
        problem="the subcommand is built from a variable or command substitution"
    elif [ "${#pos[@]}" -lt 3 ]; then
        problem="${problem:-no SQL argument, so the CLI would read stdin, which cannot be reviewed}"
    elif [ "${#pos[@]}" -gt 3 ]; then
        problem="${problem:-more than one positional argument}"
    elif [ "${posdyn[2]}" = "1" ]; then
        problem="${problem:-the SQL argument is built from a variable, glob or command substitution}"
    fi
    if [ -z "$problem" ]; then
        out=$(printf '%s' "${pos[2]}" | python3 -I "$GUARD_DIR/_sql_readonly.py" 2>&1)
        rc=$?
        if [ "$rc" != "0" ]; then
            problem="${out:-the SQL validator failed to run (rc=$rc)}"
            problem="${problem%%$'\n'*}"
        fi
    fi
    [ -z "$problem" ] && return 0
    sb_query_deny "$target" "$problem"
}

supabase_query_scan() {
    local i w lw
    local -a words=(${W[@]+"${W[@]}"})
    SBQ_FORCE_DYN=0
    if [[ $SEG_FLAGS == *U* ]] || [ -z "${W[0]:-}" ]; then
        words=(${SEG_RAW[@]+"${SEG_RAW[@]}"})
        SBQ_FORCE_DYN=1
    fi
    local n=${#words[@]}
    ((n > 0)) || return 0
    if [ -z "$SEG_CODE" ] || [ "${#SEG_REASONS[@]}" -gt 0 ]; then
        w="${words[0]##*/}"
        w="${w,,}"
        for ((i = 1; i < n; i++)); do
            lw="${words[$i],,}"
            if [[ $lw =~ (^|[^a-z0-9_])supabase([^a-z0-9_]|$) && $lw =~ (^|[^a-z0-9_])query([^a-z0-9_]|$) ]]; then
                case "$w" in
                    git | gh)
                        [[ $lw == *[=!]* || ${words[i - 1]} == -c || ${words[i - 1]} == --config-env ]] || continue
                        ;;
                esac
                deny "Blocked: an argument of \`${words[0]}\` holds a \`supabase ... query\` command line that another program may run, so the guard cannot review its SQL. Run \`supabase db query\` directly as its own command, with the SQL as one single-quoted literal: \`supabase db query --linked 'begin read only; select ...; commit;'\`. Writes must be run manually by the user."
                return 0
            fi
        done
    fi
    for ((i = 0; i < n; i++)); do
        w="${words[$i]##*/}"
        w="${w,,}"
        case "$w" in
            supabase | supabase@*) ;;
            *) continue ;;
        esac
        TOOL_ARGS=("${words[@]:i+1}")
        supabase_query_decide "$1" $((i + 1))
    done
}

supabase_decide() {
    local cwd="$1"
    tool_args supabase || return 0
    local -a args=("${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}") pos=()
    local n=${#args[@]} i=0 tok workdir="" db_url="" has_db_url=0 has_local=0 has_linked=0 has_proxy=0 flag_ref="" dry=0
    while [ "$i" -lt "$n" ]; do
        tok="${args[$i]}"
        case "$tok" in
            --workdir|--db-url|--project-ref|--project-id|--profile|--network-id|-o|--output|--dns-resolver|--agent)
                i=$((i + 1))
                case "$tok" in
                    --workdir) workdir="${args[$i]:-}" ;;
                    --db-url) db_url="${args[$i]:-}"; has_db_url=1 ;;
                    --project-ref|--project-id) flag_ref="${args[$i]:-}" ;;
                esac
                ;;
            --workdir=*) workdir="${tok#*=}" ;;
            --db-url=*) db_url="${tok#*=}"; has_db_url=1 ;;
            --project-ref=*|--project-id=*) flag_ref="${tok#*=}" ;;
            --local|--local=*) has_local=1 ;;
            --linked|--linked=*) has_linked=1 ;;
            --proxy|--proxy=*) has_proxy=1 ;;
            --dry-run|--dry-run=true) dry=1 ;;
            -*) ;;
            *) pos+=("$tok") ;;
        esac
        i=$((i + 1))
    done
    local c1="${pos[0]:-}" c2="${pos[1]:-}" label mode=""
    label="supabase $c1${c2:+ $c2}"
    [ "$c1 $c2" = "db query" ] && return 0
    case "$c1" in
        start|stop|status|init|link) return 0 ;;
        branches|postgres-config|domains|sso|network-restrictions|network-bans|ssl-enforcement|vanity-subdomains) mode=api ;;
    esac
    if [ -z "$mode" ]; then
        case "$c1 $c2" in
            "functions serve"|"migration new") return 0 ;;
            "db reset"|"migration up"|"migration down"|"migration squash"|"db diff"|"db lint"|"seed buckets"|"test db") mode=default_local ;;
            "gen types") mode=gen_types ;;
            "db push"|"migration repair"|"migration list"|"migration fetch"|"db dump"|"db pull"|"storage cp"|"storage mv"|"storage rm"|"inspect db") mode=default_linked ;;
            "functions deploy"|"functions delete"|"secrets set"|"secrets unset"|"config push"|"backups restore"|"encryption update-root-key") mode=api ;;
            "projects delete") mode=api; label="supabase projects delete"; flag_ref="${pos[2]:-$flag_ref}" ;;
            *) return 0 ;;
        esac
    fi
    if [ "$dry" = "1" ]; then
        case "$c1 $c2" in
            "db push"|"db dump") return 0 ;;
        esac
    fi
    if [ "$mode" = "api" ]; then
        supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd"
        return 0
    fi
    if [ "$has_db_url" = "1" ]; then
        supabase_db_url_verdict "$label" "$db_url"
        return 0
    fi
    [ "$has_local" = "1" ] && return 0
    if [ "$has_linked" = "1" ] || [ "$has_proxy" = "1" ]; then
        supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd"
        return 0
    fi
    case "$mode" in
        default_local) return 0 ;;
        default_linked) supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" ;;
        gen_types) [ -n "$flag_ref" ] && supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" ;;
    esac
    return 0
}

is_prod_pulumi_stack() {
    local name="${1##*/}" p
    for p in "${PULUMI_PROD_STACK_NAMES[@]}"; do
        [ "$name" = "$p" ] && return 0
    done
    return 1
}

pulumi_find_project() {
    local dir="$1"
    while :; do
        if [ -f "$dir/Pulumi.yaml" ]; then REPLY="$dir/Pulumi.yaml"; return 0; fi
        if [ -f "$dir/Pulumi.yml" ]; then REPLY="$dir/Pulumi.yml"; return 0; fi
        [ "$dir" = "/" ] || [ -z "$dir" ] && return 1
        dir="${dir%/*}"
        [ -n "$dir" ] || dir="/"
    done
}

sha1_hex() {
    if command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha1sum | cut -d' ' -f1
    else
        printf '%s' "$1" | shasum -a 1 | cut -d' ' -f1
    fi
}

PULUMI_WS_STACKS=()
pulumi_workspace_stacks() {
    local yaml="$1" backend="$2" name home path phys hash file stacks line
    PULUMI_WS_STACKS=()
    name=$(sed -nE 's/^name:[[:space:]]*["'\'']?([^"'\''[:space:]#]+).*/\1/p' "$yaml" 2>/dev/null | head -1)
    [ -n "$name" ] || return 1
    if env_get PULUMI_HOME && [ -n "$REPLY" ]; then home="$REPLY"; else home="$HOME/.pulumi"; fi
    phys="$(cd "${yaml%/*}" 2>/dev/null && pwd -P)/${yaml##*/}"
    for path in "$yaml" "$phys"; do
        hash=$(sha1_hex "$path")
        file="$home/workspaces/$name-$hash-workspace.json"
        [ -f "$file" ] && break
        file=""
    done
    [ -n "$file" ] || return 1
    stacks=$(jq -r --arg b "$backend" '
        if (.stack // "") != "" then .stack
        elif (.stacks | type) == "object" then
            (if $b != "" and (.stacks[$b] // "") != "" then .stacks[$b] else .stacks[] end)
        else empty end' "$file" 2>/dev/null)
    while IFS= read -r line; do
        [ -n "$line" ] && PULUMI_WS_STACKS+=("$line")
    done < <(printf '%s\n' "$stacks")
    [ "${#PULUMI_WS_STACKS[@]}" -gt 0 ]
}

pulumi_esc_verdict() {
    local label="$1" nm
    shift
    for nm in "$@"; do
        nm="${nm%%@*}"
        if [ -n "$nm" ] && is_prod_pulumi_stack "$nm"; then
            deny "Blocked: \`$label\` mutates the PRODUCTION ESC environment $nm. Run it manually — do not retry."
            return
        fi
    done
}

pulumi_decide() {
    local cwd="$1"
    tool_args pulumi || return 0
    local -a args=("${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}") pos=() extra_stacks=()
    local n=${#args[@]} i=0 tok val cwd_flag="" stack="" preview_only=0 create=0 esc_env=""
    while [ "$i" -lt "$n" ]; do
        tok="${args[$i]}"
        val=""
        case "$tok" in
            -C|--cwd|-s|--stack|-t|--target|--source|--dest|--env|--color|-v|--verbose|--profiling|--tracing|--memprofilerate|-m|--message|-p|--parallel|--config-file|--secrets-provider|--exec-kind|--plan|--policy-pack|--policy-pack-config)
                i=$((i + 1))
                val="${args[$i]:-}"
                case "$tok" in
                    -C|--cwd) cwd_flag="$val" ;;
                    -s|--stack) stack="$val" ;;
                    --source|--dest) extra_stacks+=("$val") ;;
                    --env) esc_env="$val" ;;
                esac
                ;;
            --cwd=*|-C=*) cwd_flag="${tok#*=}" ;;
            -C?*) cwd_flag="${tok#-C}" ;;
            --stack=*|-s=*) stack="${tok#*=}" ;;
            -s?*) stack="${tok#-s}" ;;
            --source=*|--dest=*) extra_stacks+=("${tok#*=}") ;;
            --env=*) esc_env="${tok#*=}" ;;
            --preview-only|--preview-only=true) preview_only=1 ;;
            -d)
                if [ "${pos[0]:-} ${pos[1]:-}" = "config cp" ]; then
                    i=$((i + 1))
                    extra_stacks+=("${args[$i]:-}")
                fi
                ;;
            --create|-c) create=1 ;;
            -*) ;;
            *) pos+=("$tok") ;;
        esac
        i=$((i + 1))
    done
    local c1="${pos[0]:-}" c2="${pos[1]:-}" c3="${pos[2]:-}" label kind=""
    label="pulumi $c1${c2:+ $c2}"
    case "$c1" in
        up|cancel|watch) kind=stack; label="pulumi $c1" ;;
        destroy|refresh|import)
            [ "$preview_only" = "1" ] && return 0
            kind=stack; label="pulumi $c1" ;;
        state)
            case "$c2" in delete|rename|move|unprotect|protect|repair|taint|untaint|upgrade) kind=stack ;; esac ;;
        stack)
            case "$c2" in
                rm|rename|import|change-secrets-provider) kind=stack ;;
                tag) case "$c3" in set|rm) kind=stack; label="pulumi stack tag $c3" ;; esac ;;
                select) [ "$create" = "1" ] && kind=stack ;;
            esac
            ;;
        config)
            case "$c2" in set|set-all|rm|rm-all|cp|refresh) kind=stack ;; esac ;;
        deployment)
            case "$c2" in
                run) kind=stack; label="pulumi deployment run${c3:+ $c3}" ;;
                settings) case "$c3" in init|configure|push|env|destroy) kind=stack; label="pulumi deployment settings $c3" ;; esac ;;
            esac
            ;;
        env)
            case "$c2" in
                set|edit|rotate|rm) pulumi_esc_verdict "$label" "$esc_env" "$c3" ;;
                clone) pulumi_esc_verdict "$label" "$esc_env" "$c3" "${pos[3]:-}" ;;
                version|tag)
                    local esc_name="" k
                    for ((k = 2; k < ${#pos[@]}; k++)); do
                        case "${pos[$k]}" in */*) esc_name="${pos[$k]}"; break ;; esac
                    done
                    pulumi_esc_verdict "$label" "$esc_env" "$esc_name"
                    ;;
            esac
            return 0
            ;;
    esac
    [ "$kind" = "stack" ] || return 0

    local projdir backend="" yaml="" s
    projdir="$cwd"
    if [ -n "$cwd_flag" ]; then
        abs_dir "$cwd" "$cwd_flag"
        projdir="$REPLY"
    fi
    pulumi_find_project "$projdir" && yaml="$REPLY"
    if env_get PULUMI_BACKEND_URL && [ -n "$REPLY" ]; then
        backend="$REPLY"
    elif [ -n "$yaml" ]; then
        backend=$(awk '/^backend:/{b=1;next} b&&/^[^[:space:]]/{b=0} b&&/url:/{sub(/.*url:[[:space:]]*/,""); gsub(/["\047]/,""); print; exit}' "$yaml" 2>/dev/null)
    fi
    case "$backend" in
        file://*) ;;
        *production*)
            deny "Blocked: \`$label\` runs against a production Pulumi backend. Run it manually — do not retry."
            return 0
            ;;
    esac

    local -a stacks=()
    if [ -n "$stack" ]; then
        stacks+=("$stack")
    elif [ "$c1" = "stack" ] && { [ "$c2" = "rm" ] || [ "$c2" = "select" ]; } && [ -n "$c3" ]; then
        stacks+=("$c3")
    elif env_get PULUMI_STACK && [ -n "$REPLY" ]; then
        stacks+=("$REPLY")
    elif [ -n "$yaml" ] && pulumi_workspace_stacks "$yaml" "$backend"; then
        stacks+=("${PULUMI_WS_STACKS[@]}")
    fi
    if [ "$c1 $c2" = "stack rename" ] && [ -n "$c3" ]; then
        stacks+=("$c3")
    fi
    stacks+=(${extra_stacks[@]+"${extra_stacks[@]}"})

    for s in ${stacks[@]+"${stacks[@]}"}; do
        case "$s" in *'$'*) continue ;; esac
        if is_prod_pulumi_stack "$s"; then
            deny "Blocked: \`$label\` against production stack $s. Production mutations must be run manually by the user — do not retry."
            return 0
        fi
    done
    return 0
}

seg_state_path() {
    state_path "$1" && { REPLY=$1; return 0; }
    [[ $1 != /* && $SEG_CWD_KNOWN == 1 ]] && state_path "$SEG_CWD/$1" && { REPLY="$SEG_CWD/$1"; return 0; }
    return 1
}

check_state_paths() {
    local w
    for w in ${SEG_WRITES[@]+"${SEG_WRITES[@]}"}; do
        seg_state_path "$w" && { deny "$STATE_DENY_MSG"; return; }
    done
    for w in "${W[@]:1}"; do
        seg_state_path "$w" || continue
        case "$REPLY" in
            */override | */override/*) deny "$STATE_DENY_MSG"; return ;;
        esac
        case "${W[0]##*/}" in
            cat | ls | head | tail | jq | grep | stat | wc | less) ;;
            *) deny "$STATE_DENY_MSG"; return ;;
        esac
    done
}

check_segment() {
    local j text w
    W=(${SEG_ARGV[@]+"${SEG_ARGV[@]}"})
    for ((j = 0; j < ${#W[@]}; j++)); do
        [ "${SEG_DYN:j:1}" = "1" ] && W[j]="${W[j]//$DYN/\$}"
    done
    [ -n "$SEG_CMD" ] && W[0]="$SEG_CMD"
    W[0]="${W[0],,}"
    text="${W[*]}"

    check_state_paths

    case "${W[0]}" in
        gh)
            for w in "${W[@]:1}"; do
                case "$w" in
                    --admin|--admin=*|*=--admin) deny "$GH_ADMIN_DENY_MSG" ;;
                esac
            done
            has_prefix "$text" "gh repo delete" && deny "$GH_DENY_MSG"
            ;;
        gcloud)
            has_prefix "$text" "gcloud projects delete" && deny "$GCLOUD_PROJECT_DELETE_MSG"
            if [[ "$text" =~ ^gcloud[[:space:]]+run[[:space:]]+(services[[:space:]]+(update|replace|deploy|create)|deploy)([[:space:]]|$) ]] && \
               [[ "$text" =~ --project[[:space:]]*=?[[:space:]]*${GCLOUD_RUN_PROTECTED_PROJECTS} ]]; then
                deny "Blocked: gcloud run revision-creating verb (update/replace/deploy/create) against a protected project (production-490411 / staging-480220 / mirror-production-496017). Requires explicit user execution — do not retry."
            fi
            ;;
    esac

    local cwd=""
    [ "$SEG_CWD_KNOWN" = "1" ] && cwd="$SEG_CWD"
    supabase_decide "$cwd"
    supabase_query_scan "$cwd"
    pulumi_decide "$cwd"
}

for ((seg_i = 0; seg_i < BP_N; seg_i++)); do
    bp_seg "$seg_i"
    check_segment
done

if [ -n "$VERDICT_REASON" ]; then
    hook_log "deny: $VERDICT_REASON"
    hook_decision deny "$VERDICT_REASON"
fi

exit 0

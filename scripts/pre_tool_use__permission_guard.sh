#!/bin/bash

emit_decision() {
    jq -nc --arg d "$1" --arg r "$2" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:$d,permissionDecisionReason:$r}}'
}

GUARD_INTERNAL_ERROR_MSG="GUARD_INTERNAL_ERROR: the permission guard could not complete its checks, so it is failing closed. Ask the user to run this manually or to repair scripts/_shell_command_guard.sh."

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

# shellcheck source=./_shell_command_guard.sh
if ! source "$(dirname "${BASH_SOURCE[0]}")/_shell_command_guard.sh" 2>/dev/null \
    || ! declare -F _expand_segments >/dev/null 2>&1; then
    emit_decision ask "$GUARD_INTERNAL_ERROR_MSG"
    exit 0
fi

SUPABASE_PROD_REFS=(pnseoblfzeqiczmmimnr ampdktckxcbdajezxkul)
PULUMI_PROD_STACK_NAMES=(production prod mirror main)

VERDICT=""
VERDICT_REASON=""

record_verdict() {
    case "$1" in
        deny)
            if [ "$VERDICT" != "deny" ]; then
                VERDICT="deny"
                VERDICT_REASON="$2"
            fi
            ;;
        ask)
            if [ -z "$VERDICT" ]; then
                VERDICT="ask"
                VERDICT_REASON="$2"
            fi
            ;;
    esac
}

ask() { record_verdict ask "$1"; }

deny() { record_verdict deny "$1"; }

GUARD_PREFIX_WINDOW=160

has_prefix() {
    case "$1" in
        "$2"|"$2 "*) return 0 ;;
    esac
    return 1
}

has_word() {
    case " $1 " in
        *" $2 "*) return 0 ;;
    esac
    return 1
}

SEGMENTS=()
SEGMENTS_WS=()
SEGMENTS_PFX=()
while IFS= read -r seg; do
    [ -z "$seg" ] && continue
    SEGMENTS+=("$seg")
    _ws_collapse "$seg"
    SEGMENTS_WS+=("$GUARD_REPLY")
    SEGMENTS_PFX+=("${GUARD_REPLY:0:$GUARD_PREFIX_WINDOW}")
done < <(_expand_segments "$COMMAND")

GH_DENY_MSG="Blocked: admin-required gh command. Admin actions (--admin flag, repo deletion, DELETE API calls, etc.) must be run manually by the user — do not retry. Ask the user to run it themselves."

for segment_ws in ${SEGMENTS_WS[@]+"${SEGMENTS_WS[@]}"}; do
    has_word "$segment_ws" "gh" || continue

    case " $segment_ws " in
        *" --admin "*|*" --admin="*|*"=--admin "*) deny "$GH_DENY_MSG" ;;
    esac

    if has_prefix "$segment_ws" "gh repo delete"; then
        deny "$GH_DENY_MSG"
    fi

    if has_prefix "$segment_ws" "gh api" \
        && [[ " $segment_ws " =~ (-X|--method)[[:space:]=]+[Dd][Ee][Ll][Ee][Tt][Ee]([[:space:]]|$) ]]; then
        deny "$GH_DENY_MSG"
    fi
done

GH_PATTERNS=(
    "gh repo archive"
    "gh repo unarchive"
    "gh repo rename"
    "gh repo edit"
    "gh repo autolink create"
    "gh repo autolink delete"
    "gh repo deploy-key add"
    "gh repo deploy-key delete"
    "gh pr revert"
    "gh issue delete"
    "gh issue transfer"
    "gh gist delete"
    "gh release delete"
    "gh release delete-asset"
    "gh run delete"
    "gh run cancel"
    "gh secret delete"
    "gh variable set"
    "gh variable delete"
    "gh ssh-key add"
    "gh ssh-key delete"
    "gh gpg-key add"
    "gh gpg-key delete"
    "gh codespace delete"
    "gh cache delete"
    "gh extension remove"
    "gh label delete"
    "gh project delete"
    "gh project item-delete"
    "gh project item-archive"
    "gh project field-delete"
    "gh project mark-template"
    "gh auth logout"
    "gh alias delete"
)

for pattern in "${GH_PATTERNS[@]}"; do
    for segment_pfx in ${SEGMENTS_PFX[@]+"${SEGMENTS_PFX[@]}"}; do
        if has_prefix "$segment_pfx" "$pattern"; then
            ask "gh command requires confirmation."
        fi
    done
done

for segment in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
    if [[ "$segment" =~ (^|[[:space:]])(curl|wget|http|xh)([[:space:]]) ]] && \
       [[ "$segment" =~ (-X[[:space:]]+(POST|PUT|PATCH|DELETE)|--request[[:space:]]+(POST|PUT|PATCH|DELETE)) ]] && \
       [[ "$segment" =~ api\.github\.com/repos/sunsay-ltd ]]; then
        deny "Blocked: HTTP mutation (POST/PUT/PATCH/DELETE) against api.github.com/repos/sunsay-ltd. Use the gh CLI with explicit user approval — do not bypass via raw HTTP."
    fi
done

GCLOUD_PATTERNS=(
    "gcloud projects delete"
    "gcloud resource-manager folders delete"
    "gcloud compute instances delete"
    "gcloud compute instances stop"
    "gcloud compute instances reset"
    "gcloud compute instances bulk delete"
    "gcloud compute disks delete"
    "gcloud compute disks bulk delete"
    "gcloud compute snapshots delete"
    "gcloud compute images delete"
    "gcloud compute machine-images delete"
    "gcloud compute instance-templates delete"
    "gcloud compute instance-groups managed delete"
    "gcloud compute instance-groups managed delete-instances"
    "gcloud compute instance-groups unmanaged delete"
    "gcloud compute reservations delete"
    "gcloud compute networks delete"
    "gcloud compute networks subnets delete"
    "gcloud compute firewall-rules delete"
    "gcloud compute networks peerings delete"
    "gcloud compute routes delete"
    "gcloud compute routers delete"
    "gcloud compute routers nats delete"
    "gcloud compute vpn-tunnels delete"
    "gcloud compute vpn-gateways delete"
    "gcloud compute addresses delete"
    "gcloud compute backend-services delete"
    "gcloud compute backend-buckets delete"
    "gcloud compute url-maps delete"
    "gcloud compute target-pools delete"
    "gcloud compute target-http-proxies delete"
    "gcloud compute target-https-proxies delete"
    "gcloud compute forwarding-rules delete"
    "gcloud compute health-checks delete"
    "gcloud compute ssl-certificates delete"
    "gcloud compute security-policies delete"
    "gcloud storage rm"
    "gcloud storage buckets delete"
    "gcloud sql instances delete"
    "gcloud sql databases delete"
    "gcloud sql backups delete"
    "gcloud firestore databases delete"
    "gcloud firestore bulk-delete"
    "gcloud bigtable instances delete"
    "gcloud bigtable tables delete"
    "gcloud spanner instances delete"
    "gcloud spanner databases delete"
    "gcloud alloydb clusters delete"
    "gcloud alloydb instances delete"
    "gcloud redis instances delete"
    "gcloud container clusters delete"
    "gcloud container node-pools delete"
    "gcloud container images delete"
    "gcloud run services delete"
    "gcloud run jobs delete"
    "gcloud functions delete"
    "gcloud app services delete"
    "gcloud app versions delete"
    "gcloud iam service-accounts delete"
    "gcloud iam service-accounts disable"
    "gcloud iam service-accounts keys delete"
    "gcloud iam roles delete"
    "gcloud projects remove-iam-policy-binding"
    "gcloud pubsub topics delete"
    "gcloud pubsub subscriptions delete"
    "gcloud secrets delete"
    "gcloud secrets versions destroy"
    "gcloud kms keys versions destroy"
    "gcloud dns managed-zones delete"
    "gcloud dns record-sets delete"
    "gcloud artifacts repositories delete"
    "gcloud artifacts packages delete"
    "gcloud artifacts docker images delete"
    "gcloud scheduler jobs delete"
    "gcloud tasks queues delete"
    "gcloud tasks queues purge"
    "gcloud dataflow jobs cancel"
    "gcloud dataproc clusters delete"
    "gcloud composer environments delete"
    "gcloud builds triggers delete"
    "gcloud logging sinks delete"
    "gcloud logging logs delete"
    "gcloud monitoring dashboards delete"
    "gcloud monitoring policies delete"
    "gcloud filestore instances delete"
    "gcloud notebooks instances delete"
    "gcloud workbench instances delete"
    "gcloud endpoints services delete"
    "gcloud services disable"
)

for pattern in "${GCLOUD_PATTERNS[@]}"; do
    for segment_pfx in ${SEGMENTS_PFX[@]+"${SEGMENTS_PFX[@]}"}; do
        if has_prefix "$segment_pfx" "$pattern"; then
            ask "gcloud command requires confirmation."
        fi
    done
done

GCLOUD_RUN_PROTECTED_PROJECTS='(production-490411|staging-480220|mirror-production-496017)'
for segment in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
    if [[ "$segment" =~ gcloud[[:space:]]+run[[:space:]]+(services[[:space:]]+(update|replace|deploy|create)|deploy)([[:space:]]|$) ]] && \
       [[ "$segment" =~ --project[[:space:]]*=?[[:space:]]*${GCLOUD_RUN_PROTECTED_PROJECTS} ]]; then
        deny "Blocked: gcloud run revision-creating verb (update/replace/deploy/create) against a protected project (production-490411 / staging-480220 / mirror-production-496017). Requires explicit user execution — do not retry."
    fi
done

BQ_PATTERNS=(
    "bq rm"
    "bq truncate"
)

for pattern in "${BQ_PATTERNS[@]}"; do
    for segment_pfx in ${SEGMENTS_PFX[@]+"${SEGMENTS_PFX[@]}"}; do
        if has_prefix "$segment_pfx" "$pattern"; then
            ask "bq command requires confirmation."
        fi
    done
done

CTX_SEG=()
CTX_CWD=()
CTX_ENV=()

ctx_resolve_cd() {
    local cwd="$1" target="$2" candidate resolved
    target="${target#"${target%%[![:space:]]*}"}"
    target="${target%"${target##*[![:space:]]}"}"
    case "$target" in
        ""|-|--|'$'*|'"$'*) GUARD_REPLY="$cwd"; return ;;
        \"*\") target="${target#\"}"; target="${target%\"}" ;;
        \'*\') target="${target#\'}"; target="${target%\'}" ;;
    esac
    _guard_expand_home "$target"
    target="$GUARD_REPLY"
    if [[ "$target" == /* ]]; then candidate="$target"; else candidate="$cwd/$target"; fi
    resolved=$(cd "$candidate" 2>/dev/null && pwd) || resolved="$cwd"
    GUARD_REPLY="$resolved"
}

ctx_add() {
    local seg="$1" cwd="$2" env="$3" i
    for ((i = 0; i < ${#CTX_SEG[@]}; i++)); do
        if [ "${CTX_SEG[$i]}" = "$seg" ] && [ "${CTX_CWD[$i]}" = "$cwd" ] && [ "${CTX_ENV[$i]}" = "$env" ]; then
            return
        fi
    done
    CTX_SEG+=("$seg")
    CTX_CWD+=("$cwd")
    CTX_ENV+=("$env")
}

ctx_build() {
    local session_cwd="$1" cwd split piece rest tok val env seg i known
    cwd="$session_cwd"
    split="${COMMAND//;/$'\n'}"
    split="${split//&/$'\n'}"
    split="${split//|/$'\n'}"
    while IFS= read -r piece; do
        piece="${piece#"${piece%%[![:space:]]*}"}"
        piece="${piece%"${piece##*[![:space:]]}"}"
        [ -z "$piece" ] && continue
        case "$piece" in
            cd|pushd|cd[[:space:]]*|pushd[[:space:]]*)
                rest="${piece#cd}"
                rest="${rest#pushd}"
                ctx_resolve_cd "$cwd" "$rest"
                cwd="$GUARD_REPLY"
                continue
                ;;
        esac
        env=""
        rest="$piece"
        while [ -n "$rest" ]; do
            tok="${rest%%[[:space:]]*}"
            if [[ "$tok" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                val="${tok#*=}"
                val="${val#[\"\']}"
                val="${val%[\"\']}"
                env+="${tok%%=*}=$val"$'\n'
            elif [ "$tok" != "env" ]; then
                break
            fi
            if [ "$tok" = "$rest" ]; then rest=""; else rest="${rest#*[[:space:]]}"; fi
            rest="${rest#"${rest%%[![:space:]]*}"}"
        done
        while IFS= read -r seg; do
            [ -z "$seg" ] && continue
            _ws_collapse "$seg"
            ctx_add "$GUARD_REPLY" "$cwd" "$env"
        done < <(_expand_segments "$piece")
    done < <(printf '%s\n' "$split")
    for seg in ${SEGMENTS_WS[@]+"${SEGMENTS_WS[@]}"}; do
        known=0
        for ((i = 0; i < ${#CTX_SEG[@]}; i++)); do
            [ "${CTX_SEG[$i]}" = "$seg" ] && { known=1; break; }
        done
        [ "$known" = "1" ] || ctx_add "$seg" "$session_cwd" ""
    done
}

ctx_env_get() {
    local block="$1" name="$2" line found=1 val=""
    while [ -n "$block" ]; do
        line="${block%%$'\n'*}"
        block="${block#*$'\n'}"
        case "$line" in
            "$name="*) val="${line#*=}"; found=0 ;;
        esac
    done
    if [ "$found" = "1" ] && [ -n "${!name+x}" ]; then
        val="${!name}"
        found=0
    fi
    GUARD_REPLY="$val"
    return "$found"
}

ctx_abs_dir() {
    local cwd="$1" dir="$2"
    _guard_expand_home "$dir"
    dir="$GUARD_REPLY"
    [[ "$dir" == /* ]] || dir="$cwd/$dir"
    GUARD_REPLY="$dir"
}

TOOL_ARGS=()
tool_args() {
    local seg="$1" name="$2" i=0 n tok
    local -a toks
    set -f
    # shellcheck disable=SC2206
    toks=($seg)
    set +f
    n=${#toks[@]}
    TOOL_ARGS=()
    case "${toks[0]:-}" in
        npx|bunx|pnpm|yarn|npm)
            i=1
            while [ "$i" -lt "$n" ]; do
                tok="${toks[$i]}"
                case "$tok" in
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
    TOOL_ARGS=("${toks[@]:i+1}")
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
            GUARD_REPLY="$dir/supabase/.temp/project-ref"
            return 0
        fi
        [ "$walk" = "1" ] || return 1
        [ "$dir" = "/" ] || [ -z "$dir" ] && return 1
        dir="${dir%/*}"
        [ -n "$dir" ] || dir="/"
    done
}

SB_REF=""
supabase_resolve_ref() {
    local flag_ref="$1" workdir="$2" cwd="$3" env="$4" start walk=1 ref
    SB_REF=""
    if [ -n "$flag_ref" ]; then
        SB_REF="$flag_ref"
        return
    fi
    if ctx_env_get "$env" SUPABASE_PROJECT_ID && [ -n "$GUARD_REPLY" ]; then
        SB_REF="$GUARD_REPLY"
        return
    fi
    if [ -z "$workdir" ] && ctx_env_get "$env" SUPABASE_WORKDIR && [ -n "$GUARD_REPLY" ]; then
        workdir="$GUARD_REPLY"
    fi
    if [ -n "$workdir" ]; then
        ctx_abs_dir "$cwd" "$workdir"
        start="$GUARD_REPLY"
        walk=0
    else
        start="$cwd"
    fi
    supabase_find_ref_file "$start" "$walk" || return
    ref=$(tr -d '[:space:]' <"$GUARD_REPLY" 2>/dev/null)
    SB_REF="$ref"
}

supabase_remote_verdict() {
    local label="$1" flag_ref="$2" workdir="$3" cwd="$4" env="$5"
    case "$flag_ref" in *'$'*) ask "\`$label\` targets a project ref given as a shell variable; the guard cannot tell whether it is production."; return ;; esac
    supabase_resolve_ref "$flag_ref" "$workdir" "$cwd" "$env"
    if [ -z "$SB_REF" ]; then
        ask "\`$label\` targets a remote Supabase project the guard could not resolve (no --project-ref, SUPABASE_PROJECT_ID or supabase/.temp/project-ref). Confirm it is not production."
    elif is_prod_supabase_ref "$SB_REF"; then
        deny "Blocked: \`$label\` targets the PRODUCTION Supabase project ($SB_REF). Production changes must be run manually by the user — do not retry."
    else
        ask "\`$label\` targets the non-production Supabase project $SB_REF — confirm this is intended."
    fi
}

supabase_db_url_verdict() {
    local label="$1" url="$2" host
    url="${url#[\"\']}"
    url="${url%[\"\']}"
    if text_has_prod_supabase_ref "$url"; then
        deny "Blocked: \`$label\` --db-url points at the PRODUCTION Supabase database. Production changes must be run manually by the user — do not retry."
        return
    fi
    case "$url" in
        *'$'*|'')
            ask "\`$label\` --db-url is an unresolved value ($url); the guard cannot tell whether it is production."
            return
            ;;
    esac
    host="${url#*://}"
    host="${host##*@}"
    host="${host%%[/?]*}"
    case "$host" in
        \[*\]*) host="${host#\[}"; host="${host%%\]*}" ;;
        *) host="${host%:*}" ;;
    esac
    case "$host" in
        localhost|localhost.localdomain|127.*|0.0.0.0|::1|host.docker.internal) return ;;
    esac
    ask "\`$label\` --db-url targets the remote database at $host — confirm this is intended."
}

supabase_decide() {
    local seg="$1" cwd="$2" env="$3"
    tool_args "$seg" supabase || return 0
    local -a args=("${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}") pos=()
    local n=${#args[@]} i=0 tok workdir="" db_url="" has_db_url=0 has_local=0 has_linked=0 has_proxy=0 flag_ref="" dry=0
    while [ "$i" -lt "$n" ]; do
        tok="${args[$i]}"
        case "$tok" in
            --workdir|--db-url|--project-ref|--project-id|--profile|--network-id|-o|--output|--dns-resolver)
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
    flag_ref="${flag_ref#[\"\']}"
    flag_ref="${flag_ref%[\"\']}"
    workdir="${workdir#[\"\']}"
    workdir="${workdir%[\"\']}"
    local c1="${pos[0]:-}" c2="${pos[1]:-}" label mode=""
    label="supabase $c1${c2:+ $c2}"
    case "$c1" in
        start|stop|status|init|link) return 0 ;;
        branches|postgres-config|domains|sso|network-restrictions|network-bans|ssl-enforcement|vanity-subdomains) mode=api ;;
    esac
    if [ -z "$mode" ]; then
        case "$c1 $c2" in
            "functions serve"|"migration new") return 0 ;;
            "db reset"|"migration up"|"migration down"|"migration squash"|"db diff"|"db lint"|"db query"|"seed buckets"|"test db") mode=default_local ;;
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
        supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" "$env"
        return 0
    fi
    if [ "$has_db_url" = "1" ]; then
        supabase_db_url_verdict "$label" "$db_url"
        return 0
    fi
    [ "$has_local" = "1" ] && return 0
    if [ "$has_linked" = "1" ] || [ "$has_proxy" = "1" ]; then
        supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" "$env"
        return 0
    fi
    case "$mode" in
        default_local) return 0 ;;
        default_linked) supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" "$env" ;;
        gen_types)
            if [ -n "$flag_ref" ]; then
                supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" "$env"
            else
                ask "\`$label\` has no target flag; pass --local for the local DB or --project-id/--linked for a remote project."
            fi
            ;;
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
        if [ -f "$dir/Pulumi.yaml" ]; then GUARD_REPLY="$dir/Pulumi.yaml"; return 0; fi
        if [ -f "$dir/Pulumi.yml" ]; then GUARD_REPLY="$dir/Pulumi.yml"; return 0; fi
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
    local yaml="$1" backend="$2" env="$3" name home path phys hash file stacks line
    PULUMI_WS_STACKS=()
    name=$(sed -nE 's/^name:[[:space:]]*["'\'']?([^"'\''[:space:]#]+).*/\1/p' "$yaml" 2>/dev/null | head -1)
    [ -n "$name" ] || return 1
    if ctx_env_get "$env" PULUMI_HOME && [ -n "$GUARD_REPLY" ]; then home="$GUARD_REPLY"; else home="$HOME/.pulumi"; fi
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

PT_REASON=""
pulumi_targets_tight() {
    local -a targets=("$@")
    local t
    if [ ${#targets[@]} -eq 0 ]; then
        PT_REASON="No --target specified — would mutate the entire stack. Pulumi against prod-like stacks must enumerate specific resource URNs."
        return 1
    fi
    if [ ${#targets[@]} -gt 5 ]; then
        PT_REASON="More than 5 --target flags (${#targets[@]}); this looks like enumerate-all-URNs. Split into smaller manual runs."
        return 1
    fi
    for t in "${targets[@]}"; do
        t="${t%\"}"; t="${t#\"}"
        t="${t%\'}"; t="${t#\'}"
        if [[ "$t" =~ ^urn:pulumi:[^:]+::[^:]+::pulumi:pulumi:Stack:: ]]; then
            PT_REASON="--target points at the Stack root URN ($t) — equivalent to whole-stack. Target individual resources instead."
            return 1
        fi
        if ! [[ "$t" =~ ^urn:pulumi:[^:]+::[^:]+::.+::[^:]+$ ]]; then
            PT_REASON="--target value '$t' is not a fully-qualified resource URN (urn:pulumi:<stack>::<project>::<type>::<name>). Refusing to guess."
            return 1
        fi
    done
    return 0
}

pulumi_esc_verdict() {
    local label="$1" nm
    shift
    local -a names=()
    for nm in "$@"; do
        [ -n "$nm" ] && names+=("$nm")
    done
    for nm in ${names[@]+"${names[@]}"}; do
        nm="${nm%%@*}"
        if is_prod_pulumi_stack "$nm"; then
            deny "Blocked: \`$label\` mutates the PRODUCTION ESC environment $nm. Run it manually — do not retry."
            return
        fi
    done
    if [ ${#names[@]} -eq 0 ]; then
        ask "\`$label\` mutates an ESC environment the guard could not identify — confirm it is not production."
    else
        ask "\`$label\` mutates the non-production ESC environment ${names[*]} — confirm this is intended."
    fi
}

pulumi_decide() {
    local seg="$1" cwd="$2" env="$3"
    tool_args "$seg" pulumi || return 0
    local -a args=("${TOOL_ARGS[@]+"${TOOL_ARGS[@]}"}") pos=() targets=() extra_stacks=()
    local n=${#args[@]} i=0 tok val cwd_flag="" stack="" preview_only=0 create=0 target_dependents=0 esc_env=""
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
                    -t|--target) targets+=("$val") ;;
                    --source|--dest) extra_stacks+=("$val") ;;
                    --env) esc_env="$val" ;;
                esac
                ;;
            --cwd=*|-C=*) cwd_flag="${tok#*=}" ;;
            -C?*) cwd_flag="${tok#-C}" ;;
            --stack=*|-s=*) stack="${tok#*=}" ;;
            -s?*) stack="${tok#-s}" ;;
            --target=*|-t=*) targets+=("${tok#*=}") ;;
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
            --target-dependents|--target-dependents=*) target_dependents=1 ;;
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
        policy)
            case "$c2" in
                publish|enable|disable|rm)
                    ask "\`$label\` changes organization-wide Pulumi policy enforcement, which also gates production stacks — confirm this is intended."
                    return 0
                    ;;
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
    if [ -n "$cwd_flag" ]; then
        ctx_abs_dir "$cwd" "$cwd_flag"
        projdir="$GUARD_REPLY"
    else
        projdir="$cwd"
    fi
    pulumi_find_project "$projdir" && yaml="$GUARD_REPLY"
    if ctx_env_get "$env" PULUMI_BACKEND_URL && [ -n "$GUARD_REPLY" ]; then
        backend="$GUARD_REPLY"
    elif [ -n "$yaml" ]; then
        backend=$(awk '/^backend:/{b=1;next} b&&/^[^[:space:]]/{b=0} b&&/url:/{sub(/.*url:[[:space:]]*/,""); gsub(/["\047]/,""); print; exit}' "$yaml" 2>/dev/null)
    fi
    local local_backend=0
    case "$backend" in
        file://*) local_backend=1 ;;
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
    elif ctx_env_get "$env" PULUMI_STACK && [ -n "$GUARD_REPLY" ]; then
        stacks+=("$GUARD_REPLY")
    elif [ -n "$yaml" ] && pulumi_workspace_stacks "$yaml" "$backend" "$env"; then
        stacks+=("${PULUMI_WS_STACKS[@]}")
    fi
    if [ "$c1 $c2" = "stack rename" ] && [ -n "$c3" ]; then
        stacks+=("$c3")
    fi
    stacks+=(${extra_stacks[@]+"${extra_stacks[@]}"})

    for s in ${stacks[@]+"${stacks[@]}"}; do
        case "$s" in
            *'$'*)
                ask "\`$label\` targets a stack given as a shell variable; the guard cannot tell whether it is production."
                return 0
                ;;
        esac
        is_prod_pulumi_stack "$s" || continue
        local block_prefix="Blocked: \`$label\` against production stack $s."
        case "$c1" in
            up|destroy|refresh)
                if [ "$target_dependents" = "1" ]; then
                    deny "$block_prefix --target-dependents walks the dependency graph and is effectively whole-stack. Run manually."
                elif pulumi_targets_tight ${targets[@]+"${targets[@]}"}; then
                    ask "\`$label\` against production stack $s with a tight --target set — confirm each URN is intended."
                else
                    deny "$block_prefix $PT_REASON"
                fi
                ;;
            *) deny "$block_prefix Production mutations must be run manually by the user — do not retry." ;;
        esac
        return 0
    done

    if [ ${#stacks[@]} -eq 0 ]; then
        ask "\`$label\` mutates a Pulumi stack the guard could not resolve (no -s/--stack, PULUMI_STACK or selected workspace stack). Confirm it is not production."
    elif [ "$local_backend" = "0" ]; then
        ask "\`$label\` mutates the non-production stack ${stacks[*]} — confirm this is intended."
    fi
    return 0
}

case "$COMMAND" in
    *supabase*|*pulumi*)
        SESSION_CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
        [ -n "$SESSION_CWD" ] || SESSION_CWD="$PWD"
        ctx_build "$SESSION_CWD"
        for ((ctx_i = 0; ctx_i < ${#CTX_SEG[@]}; ctx_i++)); do
            supabase_decide "${CTX_SEG[$ctx_i]}" "${CTX_CWD[$ctx_i]}" "${CTX_ENV[$ctx_i]}"
            pulumi_decide "${CTX_SEG[$ctx_i]}" "${CTX_CWD[$ctx_i]}" "${CTX_ENV[$ctx_i]}"
        done
        ;;
esac

if [ -n "$VERDICT" ]; then
    emit_decision "$VERDICT" "$VERDICT_REASON"
fi

exit 0

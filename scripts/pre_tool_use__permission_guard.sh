#!/bin/bash

GUARD_DIR=.
[[ ${BASH_SOURCE[0]} == */* ]] && GUARD_DIR=${BASH_SOURCE[0]%/*}
GUARD_INTERNAL_ERROR_JSON='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"GUARD_INTERNAL_ERROR: the permission guard could not complete its checks, so it is failing closed. Ask the user to run this manually or to repair scripts/_bashparse.sh."}}'

if [[ ${BP_READY:-} != 1 ]] || ! declare -F bp_hook_prepare >/dev/null; then
    IFS= read -r -d '' INPUT
    if ! source "$GUARD_DIR/_hook_log.sh" 2>/dev/null || ! source "$GUARD_DIR/_bashparse.sh" 2>/dev/null; then
        printf '%s\n' "$GUARD_INTERNAL_ERROR_JSON"
        exit 0
    fi
    bp_hook_prepare "$INPUT"
fi
((BP_RC == 0)) || fail_closed "the permission guard could not parse the command ($BP_ERR)"
[[ $BP_TOOL == Bash ]] || exit 0

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

GH_DENY_MSG="Blocked: admin-required gh command. Admin actions (--admin flag, repo deletion, etc.) must be run manually by the user — do not retry. Ask the user to run it themselves."
GCLOUD_RUN_PROTECTED_PROJECTS='(production-490411|staging-480220|mirror-production-496017)'
GUARDED_TOOLS_RE='(^|[^A-Za-z0-9_.-])(gh|gcloud|bq|curl|wget|http|xh|supabase|pulumi)([^A-Za-z0-9_.-]|$)'
DYN=$'\xef\xbf\xbd'

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
        npx|bunx|pnpm|yarn|npm)
            i=1
            while [ "$i" -lt "$n" ]; do
                tok="${W[$i]}"
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
    TOOL_ARGS=("${W[@]:i+1}")
    return 0
}

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

BQ_PATTERNS=(
    "bq rm"
    "bq truncate"
)

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
    case "$flag_ref" in *'$'*) ask "\`$label\` targets a project ref given as a shell variable; the guard cannot tell whether it is production."; return ;; esac
    supabase_resolve_ref "$flag_ref" "$workdir" "$cwd"
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
    local cwd="$1"
    tool_args supabase || return 0
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
        gen_types)
            if [ -n "$flag_ref" ]; then
                supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd"
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
    local cwd="$1"
    tool_args pulumi || return 0
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

check_unknown() {
    local r raw
    for r in ${SEG_REASONS[@]+"${SEG_REASONS[@]}"}; do
        case "$r" in
            source) ;;
            "indirect exec")
                printf -v raw '%s ' ${SEG_RAW[@]+"${SEG_RAW[@]}"}
                if [[ "$raw" =~ $GUARDED_TOOLS_RE ]]; then
                    ask "This command hands a guarded tool (${BASH_REMATCH[2]}) to xargs/find/parallel, so the guard cannot check it. Confirm it is safe."
                fi
                ;;
            *) ask "The guard cannot see what part of this command runs ($r). Confirm it is safe." ;;
        esac
    done
}

check_segment() {
    local j pattern text w
    W=(${SEG_ARGV[@]+"${SEG_ARGV[@]}"})
    for ((j = 0; j < ${#W[@]}; j++)); do
        [ "${SEG_DYN:j:1}" = "1" ] && W[j]="${W[j]//$DYN/\$}"
    done
    [ -n "$SEG_CMD" ] && W[0]="$SEG_CMD"
    text="${W[*]}"

    case "$SEG_FLAGS" in *U*) check_unknown ;; esac

    case "$SEG_CMD" in
        gh)
            for w in "${W[@]:1}"; do
                case "$w" in
                    --admin|--admin=*|*=--admin) deny "$GH_DENY_MSG" ;;
                esac
            done
            has_prefix "$text" "gh repo delete" && deny "$GH_DENY_MSG"
            for pattern in "${GH_PATTERNS[@]}"; do
                has_prefix "$text" "$pattern" && ask "gh command requires confirmation."
            done
            ;;
        curl|wget|http|xh)
            if [[ "$text" =~ (-X[[:space:]]*|--request[[:space:]=]+)(POST|PUT|PATCH|DELETE)([[:space:]]|$) ]] && \
               [[ "$text" =~ api\.github\.com/repos/sunsay-ltd ]]; then
                deny "Blocked: HTTP mutation (POST/PUT/PATCH/DELETE) against api.github.com/repos/sunsay-ltd. Use the gh CLI with explicit user approval — do not retry via raw HTTP."
            fi
            ;;
        gcloud)
            for pattern in "${GCLOUD_PATTERNS[@]}"; do
                has_prefix "$text" "$pattern" && ask "gcloud command requires confirmation."
            done
            if [[ "$text" =~ ^gcloud[[:space:]]+run[[:space:]]+(services[[:space:]]+(update|replace|deploy|create)|deploy)([[:space:]]|$) ]] && \
               [[ "$text" =~ --project[[:space:]]*=?[[:space:]]*${GCLOUD_RUN_PROTECTED_PROJECTS} ]]; then
                deny "Blocked: gcloud run revision-creating verb (update/replace/deploy/create) against a protected project (production-490411 / staging-480220 / mirror-production-496017). Requires explicit user execution — do not retry."
            fi
            ;;
        bq)
            for pattern in "${BQ_PATTERNS[@]}"; do
                has_prefix "$text" "$pattern" && ask "bq command requires confirmation."
            done
            ;;
    esac

    local cwd=""
    [ "$SEG_CWD_KNOWN" = "1" ] && cwd="$SEG_CWD"
    supabase_decide "$cwd"
    pulumi_decide "$cwd"
}

for ((seg_i = 0; seg_i < BP_N; seg_i++)); do
    bp_seg "$seg_i"
    check_segment
done

if [ -n "$VERDICT" ]; then
    hook_log "$VERDICT: $VERDICT_REASON"
    hook_decision "$VERDICT" "$VERDICT_REASON"
fi

exit 0

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
GUARDED_TOOLS_RE='(^|[^A-Za-z0-9_.-])(gh|gcloud|bq|supabase|pulumi)([^A-Za-z0-9_.-]|$)'
if ((BP_RC != 0)); then
    if [[ ${BP_CMD:-${HOOK_LOG_CMD:-}} =~ $GUARDED_TOOLS_RE ]]; then
        hook_log "deny: unparseable command mentions ${BASH_REMATCH[2]} ($BP_ERR)"
        if ((BP_RC == 3)); then
            hook_decision deny "DENIED: the permission guard needs shfmt to parse Bash commands that mention ${BASH_REMATCH[2]}, and shfmt is not installed. Run \`brew install shfmt\` in its own Bash call, then retry this command unchanged."
        else
            hook_decision deny "DENIED: the permission guard could not parse this command ($BP_ERR), and it mentions ${BASH_REMATCH[2]}, so it cannot verify the ${BASH_REMATCH[2]} call is safe. Rewrite: run the ${BASH_REMATCH[2]} command alone in its own Bash call as a plain command with literal arguments (no heredoc, eval, unusual quoting, or very long chains), and put every other step in a separate Bash call."
        fi
    fi
    exit 0
fi
STATE_ROOT_GUARD="${CLAUDE_STATE_DIR:-$HOME/.claude/state}"
STATE_DENY_MSG="DENIED: ~/.claude/state holds the Stop gate's session ledger and its kill switch. Only the gate's own scripts write there (done_gate.sh predicate|check, the merge trigger, the post-merge watcher). Do not create, edit or delete these files: satisfy the gate instead (finish the work, start a real watcher, or end with \`STATUS: FAILURE <what>: <evidence>\`). The kill switch is for the user only."

state_path() {
    local p=$1 tilde='~'
    case "$p" in
        "$tilde"/*) p="$HOME/${p#"$tilde"/}" ;;
        '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
        '${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
    esac
    case "$p" in
        "$STATE_ROOT_GUARD" | "$STATE_ROOT_GUARD"/* | *.claude/state | *.claude/state/*) return 0 ;;
    esac
    return 1
}

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
GH_ADMIN_DENY_MSG="Blocked: \`--admin\` bypasses required checks. Run \`gh pr checks <n>\`, find the failing required check, fix its cause (a CVE: bump the dependency; a migration lint: fix the migration), push, and merge normally on green with \`gh pr merge <n> --squash --match-head-commit <sha>\`. Do not hand the merge to the user. If a required check cannot pass by design, end with \`STATUS: FAILURE admin-merge: <check> fails because <evidence>\`."
GCLOUD_RUN_PROTECTED_PROJECTS='(production-490411|staging-480220|mirror-production-496017)'
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
    local label="$1" flag_ref="$2" workdir="$3" cwd="$4" readonly="$5"
    case "$flag_ref" in *'$'*) deny "DENIED: \`$label\` takes its project ref from a shell variable ($flag_ref), so the guard cannot tell whether it targets production. Rewrite with the literal ref: \`$label --project-ref <20-char-ref>\`, or use \`--local\` for the local stack."; return ;; esac
    supabase_resolve_ref "$flag_ref" "$workdir" "$cwd"
    if [ -z "$SB_REF" ]; then
        deny "DENIED: \`$label\` targets a remote Supabase project the guard could not resolve (no --project-ref, SUPABASE_PROJECT_ID or supabase/.temp/project-ref under the working directory). Rewrite with an explicit target: \`--local\` for the local stack, \`--project-ref <20-char-ref>\` for API commands (functions, secrets, config, branches), \`--db-url <literal url>\`, or \`--workdir <abs dir whose supabase/.temp/project-ref is linked>\`."
    elif is_prod_supabase_ref "$SB_REF"; then
        deny "Blocked: \`$label\` targets the PRODUCTION Supabase project ($SB_REF). Production changes must be run manually by the user — do not retry."
    elif [ "$readonly" != "1" ]; then
        ask "\`$label\` changes the remote non-production Supabase project $SB_REF (shared environment) — confirm this is intended."
    fi
}

supabase_db_url_verdict() {
    local label="$1" url="$2" readonly="$3" host
    if text_has_prod_supabase_ref "$url"; then
        deny "Blocked: \`$label\` --db-url points at the PRODUCTION Supabase database. Production changes must be run manually by the user — do not retry."
        return
    fi
    case "$url" in
        *'$'*|'')
            deny "DENIED: \`$label\` --db-url is an unresolved value ($url), so the guard cannot tell whether it is production. Rewrite with the literal connection string (e.g. \`--db-url postgresql://postgres:postgres@127.0.0.1:54322/postgres\`), or use \`--local\` / \`--project-ref <ref>\` instead of --db-url."
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
    [ "$readonly" = "1" ] && return
    ask "\`$label\` --db-url changes the remote database at $host — confirm this is intended."
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
    local c1="${pos[0]:-}" c2="${pos[1]:-}" label mode="" ro=0
    label="supabase $c1${c2:+ $c2}"
    case "$c1 $c2" in
        "migration list"|"migration fetch"|"db dump"|"inspect db"|"gen types"|"db diff"|"db lint") ro=1 ;;
    esac
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
        supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" "$ro"
        return 0
    fi
    if [ "$has_db_url" = "1" ]; then
        supabase_db_url_verdict "$label" "$db_url" "$ro"
        return 0
    fi
    [ "$has_local" = "1" ] && return 0
    if [ "$has_linked" = "1" ] || [ "$has_proxy" = "1" ]; then
        supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" "$ro"
        return 0
    fi
    case "$mode" in
        default_local) return 0 ;;
        default_linked) supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" "$ro" ;;
        gen_types)
            if [ -n "$flag_ref" ]; then
                supabase_remote_verdict "$label" "$flag_ref" "$workdir" "$cwd" "$ro"
            else
                deny "DENIED: \`$label\` has no target flag, so the guard cannot tell which database it reads. Rewrite with an explicit target: \`$label --local\` for the local DB, or \`$label --project-id <20-char-ref>\` for a remote non-production project."
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
        deny "DENIED: \`$label\` mutates an ESC environment the guard could not identify, so it cannot tell whether it is production. Rewrite naming the environment literally as a positional argument: \`$label <org>/<project>/<env> ...\` (no shell variables)."
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
                deny "DENIED: \`$label\` takes its stack from a shell variable ($s), so the guard cannot tell whether it is production. Rewrite with the literal stack name: \`$label -s <org>/<project>/<stack>\`."
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
        deny "DENIED: \`$label\` mutates a Pulumi stack the guard could not resolve (no -s/--stack, PULUMI_STACK, or selected workspace stack for the project in the working directory). Rewrite with an explicit literal stack: \`$label -s <org>/<project>/<stack>\`, adding \`-C <abs project dir>\` if the Pulumi.yaml is not in the working directory."
    elif [ "$local_backend" = "0" ]; then
        ask "\`$label\` mutates the non-production stack ${stacks[*]} — confirm this is intended."
    fi
    return 0
}

check_unknown() {
    local r tool fix
    [[ $BP_CMD =~ $GUARDED_TOOLS_RE ]] || return 0
    tool=${BASH_REMATCH[2]}
    for r in ${SEG_REASONS[@]+"${SEG_REASONS[@]}"}; do
        [ "$r" = source ] && continue
        case "$r" in
            "dynamic command name"|"substitution as command")
                fix="Never run a command through a variable or \$(...) as its name (e.g. \`K=node_modules/.bin/x; \$K run\`); write the literal command path, e.g. \`/abs/path/node_modules/.bin/x run ...\`." ;;
            "indirect exec")
                fix="Do not hand commands to xargs, parallel, or find -exec when the line mentions $tool; run each $tool call directly with literal arguments in its own Bash call, and use the Grep/Glob tools or plain \`grep -r\`/\`rg\` for searches instead of piping into xargs." ;;
            "dynamic eval"|"dynamic shell code"|"dynamic shell heredoc")
                fix="Do not use eval, \`bash -c \"\$VAR\"\`, or a heredoc built from variables; write the commands out literally (e.g. run \`devtrees env\` first, read the value, then use it as a literal in the next call)." ;;
            "shell reads stdin")
                fix="Do not pipe or redirect a script into bash/sh/zsh; run the commands directly, or write the script to a file in the scratchpad and run \`bash /abs/path/script.sh\`." ;;
            *)
                fix="Run the $tool command alone in its own Bash call as a plain command with literal arguments, and put other steps in separate calls." ;;
        esac
        deny "DENIED: the permission guard cannot see what part of this command runs ($r), and the command mentions $tool, so it cannot verify the $tool call is safe. $fix"
    done
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
    local j pattern text w
    W=(${SEG_ARGV[@]+"${SEG_ARGV[@]}"})
    for ((j = 0; j < ${#W[@]}; j++)); do
        [ "${SEG_DYN:j:1}" = "1" ] && W[j]="${W[j]//$DYN/\$}"
    done
    [ -n "$SEG_CMD" ] && W[0]="$SEG_CMD"
    text="${W[*]}"

    case "$SEG_FLAGS" in *U*) check_unknown ;; esac

    check_state_paths

    case "$SEG_CMD" in
        gh)
            for w in "${W[@]:1}"; do
                case "$w" in
                    --admin|--admin=*|*=--admin) deny "$GH_ADMIN_DENY_MSG" ;;
                esac
            done
            has_prefix "$text" "gh repo delete" && deny "$GH_DENY_MSG"
            for pattern in "${GH_PATTERNS[@]}"; do
                has_prefix "$text" "$pattern" && ask "\`$pattern\` is destructive or changes shared GitHub settings, so it needs the user's confirmation."
            done
            ;;
        gcloud)
            for pattern in "${GCLOUD_PATTERNS[@]}"; do
                has_prefix "$text" "$pattern" && ask "\`$pattern\` deletes or disables Google Cloud resources, so it needs the user's confirmation."
            done
            if [[ "$text" =~ ^gcloud[[:space:]]+run[[:space:]]+(services[[:space:]]+(update|replace|deploy|create)|deploy)([[:space:]]|$) ]] && \
               [[ "$text" =~ --project[[:space:]]*=?[[:space:]]*${GCLOUD_RUN_PROTECTED_PROJECTS} ]]; then
                deny "Blocked: gcloud run revision-creating verb (update/replace/deploy/create) against a protected project (production-490411 / staging-480220 / mirror-production-496017). Requires explicit user execution — do not retry."
            fi
            ;;
        bq)
            for pattern in "${BQ_PATTERNS[@]}"; do
                has_prefix "$text" "$pattern" && ask "\`$pattern\` deletes BigQuery data, so it needs the user's confirmation."
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

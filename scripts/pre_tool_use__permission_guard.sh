#!/bin/bash

emit_decision() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
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

supabase_json_safe() {
    echo "$1" | tr -d '"\\%' | tr -d '\n'
}

supabase_db_url_value() {
    echo "$1" | sed -nE "s/.*--db-url[[:space:]=]+[\"']?([^\"'[:space:]]+).*/\1/p"
}

supabase_db_url_host() {
    echo "$1" | sed -E 's#^[a-zA-Z0-9+.-]+://##; s#^[^@/]*@##; s#[/?].*$##; s#:[0-9]+$##; s#^\[(.*)\]$#\1#'
}

supabase_db_url_is_local() {
    local url host
    url=$(supabase_db_url_value "$1")
    [ -n "$url" ] || return 1
    host=$(supabase_db_url_host "$url")
    case "$host" in
        localhost | localhost.localdomain | 127.*.*.* | 0.0.0.0 | ::1 | host.docker.internal) return 0 ;;
        *) return 1 ;;
    esac
}

supabase_has_target_flag() {
    case " $1 " in
        *" --local "*|*" --local="*|*" --linked "*|*" --linked="*) return 0 ;;
        *" --proxy "*|*" --proxy="*|*" --db-url "*|*" --db-url="*) return 0 ;;
    esac
    return 1
}

supabase_targets_local() {
    local seg="$1"
    case " $seg " in
        *" --local "*|*" --local="*) return 0 ;;
    esac
    case " $seg " in
        *" --db-url "*|*" --db-url="*)
            supabase_db_url_is_local "$seg" && return 0
            ;;
    esac
    return 1
}

supabase_remote_detail() {
    local seg="$1" url host
    case " $seg " in
        *" --linked "*|*" --linked="*)
            echo "--linked targets the linked cloud project"
            return
            ;;
        *" --proxy "*|*" --proxy="*)
            echo "--proxy targets the linked cloud project through the Supabase API"
            return
            ;;
    esac
    url=$(supabase_db_url_value "$seg")
    host=$(supabase_db_url_host "$url")
    if [ -n "$host" ] && echo "$host" | grep -qE '^[A-Za-z0-9._-]+$'; then
        echo "--db-url targets the DB at $(supabase_json_safe "$host")"
    else
        echo "--db-url targets an unresolved remote DB ($(supabase_json_safe "$url"))"
    fi
}

SUPABASE_PATTERNS=(
    "supabase projects delete"
    "supabase storage rm"
    "supabase sso remove"
    "supabase backups restore"
    "supabase functions delete"
    "supabase secrets unset"
    "supabase domains delete"
    "supabase vanity-subdomains delete"
    "supabase stop"
    "supabase migration push"
    "supabase branches delete"
    "supabase branches pause"
    "supabase postgres-config delete"
    "supabase config push"
    "supabase ssl-enforcement update"
    "supabase network-restrictions update"
    "supabase network-bans remove"
    "supabase encryption update-root-key"
    "supabase storage mv"
)

SUPABASE_TARGET_AWARE_PATTERNS=(
    "supabase db reset"
    "supabase migration up"
    "supabase migration down"
    "supabase migration squash"
    "supabase db push"
    "supabase migration repair"
)

for pattern in "${SUPABASE_PATTERNS[@]}"; do
    for segment_pfx in ${SEGMENTS_PFX[@]+"${SEGMENTS_PFX[@]}"}; do
        if has_prefix "$segment_pfx" "$pattern"; then
            ask "supabase command requires confirmation."
        fi
    done
done

for pattern in "${SUPABASE_TARGET_AWARE_PATTERNS[@]}"; do
    for ((seg_i = 0; seg_i < ${#SEGMENTS_WS[@]}; seg_i++)); do
        segment_ws="${SEGMENTS_WS[$seg_i]}"
        has_prefix "${SEGMENTS_PFX[$seg_i]}" "$pattern" || continue

        if supabase_targets_local "$segment_ws"; then
            continue
        fi

        if ! supabase_has_target_flag "$segment_ws"; then
            deny "Blocked: \`${pattern}\` needs an explicit target — add --local to hit the local dev DB, or --linked/--db-url <remote> to target remote (remote will then require confirmation)."
            continue
        fi

        ask "\`${pattern}\` $(supabase_remote_detail "$segment_ws") — confirm this is intended."
    done
done

pulumi_target_guard() {
    local seg="$1"

    local stripped
    stripped=$(echo "$seg" \
        | sed -E 's/^[[:space:]]*pulumi[[:space:]]+//' \
        | sed -E 's/-C[[:space:]]+[^ ]+[[:space:]]*//g' \
        | sed -E 's/--cwd[[:space:]]+[^ ]+[[:space:]]*//g' \
        | sed -E 's/^[[:space:]]+//')
    [[ "$stripped" =~ ^(up|destroy|cancel)([[:space:]]|$) ]] || return 0

    local stack=""
    if [[ "$seg" =~ (--stack|[[:space:]]-s)[[:space:]]*=?[[:space:]]*([A-Za-z0-9._/-]+) ]]; then
        stack="${BASH_REMATCH[2]}"
    fi
    [[ -n "$stack" ]] || return 0
    case "$stack" in
        production|prod|mirror|main) ;;
        *) return 0 ;;
    esac

    local block_prefix="Blocked: pulumi against --stack $stack without a tight --target set."

    if [[ "$seg" =~ (^|[[:space:]])--target-dependents([[:space:]]|=|$) ]]; then
        deny "${block_prefix} --target-dependents walks the dependency graph and is effectively whole-stack. Run manually."
    fi

    local -a targets=()
    # shellcheck disable=SC2206
    local tokens=( $seg )
    local i=0
    local n=${#tokens[@]}
    while [ $i -lt $n ]; do
        local tok="${tokens[$i]}"
        case "$tok" in
            --target|-t)
                i=$((i+1))
                [ $i -lt $n ] && targets+=("${tokens[$i]}")
                ;;
            --target=*)
                targets+=("${tok#--target=}")
                ;;
            -t=*)
                targets+=("${tok#-t=}")
                ;;
        esac
        i=$((i+1))
    done

    if [ ${#targets[@]} -eq 0 ]; then
        deny "${block_prefix} No --target specified — would mutate the entire stack. Pulumi against prod-like stacks must enumerate specific resource URNs."
    fi

    if [ ${#targets[@]} -gt 5 ]; then
        deny "${block_prefix} More than 5 --target flags (${#targets[@]}); this looks like enumerate-all-URNs. Split into smaller manual runs."
    fi

    local t
    for t in "${targets[@]}"; do
        t="${t%\"}"; t="${t#\"}"
        t="${t%\'}"; t="${t#\'}"

        if [[ "$t" =~ ^urn:pulumi:[^:]+::[^:]+::pulumi:pulumi:Stack:: ]]; then
            deny "${block_prefix} --target points at the Stack root URN ($t) — equivalent to whole-stack. Target individual resources instead."
        fi

        if ! [[ "$t" =~ ^urn:pulumi:[^:]+::[^:]+::.+::[^:]+$ ]]; then
            deny "${block_prefix} --target value '$t' is not a fully-qualified resource URN (urn:pulumi:<stack>::<project>::<type>::<name>). Refusing to guess."
        fi
    done
}

for ((seg_i = 0; seg_i < ${#SEGMENTS_WS[@]}; seg_i++)); do
    has_prefix "${SEGMENTS_PFX[$seg_i]}" "pulumi" || continue
    pulumi_target_guard "${SEGMENTS_WS[$seg_i]}"
done

PULUMI_SEG_FOUND=0
for segment_pfx in ${SEGMENTS_PFX[@]+"${SEGMENTS_PFX[@]}"}; do
    if has_prefix "$segment_pfx" "pulumi"; then
        PULUMI_SEG_FOUND=1
        break
    fi
done
if [ "$PULUMI_SEG_FOUND" = "1" ]; then
    PULUMI_WRITE_SUBCMDS=(
        "up"
        "destroy"
        "refresh"
        "import"
        "watch"
        "cancel"
        "new"
        "convert"
        "install"
        "login"
        "logout"
        "stack init"
        "stack rm"
        "stack rename"
        "stack import"
        "stack export"
        "stack change-secrets-provider"
        "config set"
        "config set-all"
        "config rm"
        "config rm-all"
        "config cp"
        "config refresh"
        "config env add"
        "config env rm"
        "state delete"
        "state unprotect"
        "state protect"
        "state move"
        "state rename"
        "state repair"
        "state upgrade"
        "env new"
        "env set"
        "env rm"
        "env clone"
        "env edit"
        "env version tag"
        "env version retract"
        "policy new"
        "policy publish"
        "policy enable"
        "policy disable"
        "policy rm"
        "package add"
        "plugin install"
        "plugin rm"
    )

    for ((seg_i = 0; seg_i < ${#SEGMENTS_WS[@]}; seg_i++)); do
        has_prefix "${SEGMENTS_PFX[$seg_i]}" "pulumi" || continue
        segment_ws="${SEGMENTS_WS[$seg_i]}"
        EFFECTIVE=$(echo "$segment_ws" \
            | sed -E 's/^[[:space:]]*pulumi[[:space:]]+//' \
            | sed -E 's/-C[[:space:]]+[^ ]+[[:space:]]*//g' \
            | sed -E 's/--cwd[[:space:]]+[^ ]+[[:space:]]*//g' \
            | sed -E 's/-s[[:space:]]+[^ ]+[[:space:]]*//g' \
            | sed -E 's/--stack[[:space:]]+[^ ]+[[:space:]]*//g' \
            | sed -E 's/--color[[:space:]]+[^ ]+[[:space:]]*//g' \
            | sed -E 's/-v[[:space:]]+[^ ]+[[:space:]]*//g' \
            | sed -E 's/--verbose[[:space:]]+[^ ]+[[:space:]]*//g' \
            | sed -E 's/--[a-z-]*[[:space:]]*//g' \
            | sed -E 's/[[:space:]]+/ /g' \
            | sed -E 's/^[[:space:]]*//')
        for subcmd in "${PULUMI_WRITE_SUBCMDS[@]}"; do
            if has_prefix "$EFFECTIVE" "$subcmd"; then
                ask "pulumi command requires confirmation."
            fi
        done
    done
fi

if [ -n "$VERDICT" ]; then
    emit_decision "$VERDICT" "$VERDICT_REASON"
fi

exit 0

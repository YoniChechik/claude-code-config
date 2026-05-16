#!/bin/bash

# PreToolUse hook: unified ask-guard that replaces all permissions.ask entries
# in settings.json. Reads stdin JSON, extracts tool_name and tool_input.command,
# and prompts for confirmation when the command matches a known destructive pattern.
#
# Also handles pulumi commands invoked with -C / --cwd flags that precede the
# subcommand (e.g. "pulumi -C infra up"), which simple prefix rules would miss.
#
# Exit 0 = no opinion (let other rules decide).
# Outputs JSON with permissionDecision=ask to trigger a confirmation prompt.

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

ask() {
    local reason="$1"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$reason"
    exit 0
}

# Hard-deny: blocks the LLM from running the command. Unlike `ask`, the user
# is NOT prompted — the model is told to stop and ask the human to run it.
deny() {
    local reason="$1"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
    exit 0
}

# Split the compound command on separators (;, &&, ||, |, newlines) into
# individual segments. Each segment is matched independently against the
# protected-pattern lists below — this closes the bypass where
# `cd foo && gh pr merge ...` slipped through because the full command
# string didn't start with `gh`.
SEGMENTS=()
while IFS= read -r seg; do
    # Strip leading/trailing whitespace
    seg="${seg#"${seg%%[![:space:]]*}"}"
    seg="${seg%"${seg##*[![:space:]]}"}"
    [ -z "$seg" ] && continue
    SEGMENTS+=("$seg")
done < <(echo "$COMMAND" | tr ';&|' '\n')

# ---------------------------------------------------------------------------
# gh — hard-deny for admin-gated commands. These bypass branch protections,
# destroy repos, or otherwise require GitHub admin privileges; the LLM must
# NOT run them. The user runs these manually.
# ---------------------------------------------------------------------------
GH_DENY_MSG="Blocked: admin-required gh command. Admin actions (--admin flag, repo deletion, DELETE API calls, etc.) must be run manually by the user — do not retry. Ask the user to run it themselves."

for segment in "${SEGMENTS[@]}"; do
    # Only inspect segments that invoke `gh`.
    echo "$segment" | grep -qE '(^|\s)gh(\s|$)' || continue

    # 1) Any `gh ...` invocation that carries the `--admin` flag token.
    #    Matches `gh pr merge --admin 123`, `gh pr merge 123 --admin`, etc.
    if echo "$segment" | grep -qE '(^|\s)gh\s.*(\s|=)--admin(\s|=|$)'; then
        deny "$GH_DENY_MSG"
    fi

    # 2) Repository deletion — irreversible, requires admin.
    if echo "$segment" | grep -qE '^\s*gh\s+repo\s+delete(\s|$)'; then
        deny "$GH_DENY_MSG"
    fi

    # 3) Raw API DELETE calls via `gh api`: `-X DELETE` or `--method DELETE`
    #    (case-insensitive on the verb).
    if echo "$segment" | grep -qE '^\s*gh\s+api\s' \
        && echo "$segment" | grep -qiE '(-X|--method)(\s+|=)DELETE(\s|$)'; then
        deny "$GH_DENY_MSG"
    fi
done

# ---------------------------------------------------------------------------
# gh
# ---------------------------------------------------------------------------
GH_PATTERNS=(
    "gh repo delete"
    "gh repo archive"
    "gh repo unarchive"
    "gh repo rename"
    "gh repo edit"
    "gh repo autolink create"
    "gh repo autolink delete"
    "gh repo deploy-key add"
    "gh repo deploy-key delete"
    "gh pr merge"
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
    for segment in "${SEGMENTS[@]}"; do
        if echo "$segment" | grep -qE "^${pattern}(\s|$)"; then
            ask "gh command requires confirmation."
        fi
    done
done

# ---------------------------------------------------------------------------
# gcloud
# ---------------------------------------------------------------------------
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
    for segment in "${SEGMENTS[@]}"; do
        if echo "$segment" | grep -qE "^${pattern}(\s|$)"; then
            ask "gcloud command requires confirmation."
        fi
    done
done

# ---------------------------------------------------------------------------
# bq
# ---------------------------------------------------------------------------
BQ_PATTERNS=(
    "bq rm"
    "bq truncate"
)

for pattern in "${BQ_PATTERNS[@]}"; do
    for segment in "${SEGMENTS[@]}"; do
        if echo "$segment" | grep -qE "^${pattern}(\s|$)"; then
            ask "bq command requires confirmation."
        fi
    done
done

# ---------------------------------------------------------------------------
# supabase
# ---------------------------------------------------------------------------
SUPABASE_PATTERNS=(
    "supabase projects delete"
    "supabase db reset"
    "supabase storage rm"
    "supabase sso remove"
    "supabase backups restore"
    "supabase migration down"
    "supabase functions delete"
    "supabase secrets unset"
    "supabase domains delete"
    "supabase vanity-subdomains delete"
    "supabase stop"
    "supabase db push"
    "supabase migration push"
    "supabase branches delete"
    "supabase branches pause"
    "supabase postgres-config delete"
    "supabase migration repair"
    "supabase migration squash"
    "supabase config push"
    "supabase ssl-enforcement update"
    "supabase network-restrictions update"
    "supabase network-bans remove"
    "supabase encryption update-root-key"
    "supabase storage mv"
)

for pattern in "${SUPABASE_PATTERNS[@]}"; do
    for segment in "${SEGMENTS[@]}"; do
        if echo "$segment" | grep -qE "^${pattern}(\s|$)"; then
            ask "supabase command requires confirmation."
        fi
    done
done

# ---------------------------------------------------------------------------
# pulumi — direct prefix match (covers straightforward invocations)
# ---------------------------------------------------------------------------
PULUMI_PATTERNS=(
    "pulumi up"
    "pulumi destroy"
    "pulumi import"
    "pulumi refresh"
    "pulumi cancel"
    "pulumi stack rm"
    "pulumi stack init"
    "pulumi stack rename"
    "pulumi stack import"
    "pulumi config set"
    "pulumi config rm"
    "pulumi state delete"
    "pulumi state unprotect"
    "pulumi state move"
    "pulumi env rm"
    "pulumi new"
)

for pattern in "${PULUMI_PATTERNS[@]}"; do
    for segment in "${SEGMENTS[@]}"; do
        if echo "$segment" | grep -qE "^${pattern}(\s|$)"; then
            ask "pulumi command requires confirmation."
        fi
    done
done

# ---------------------------------------------------------------------------
# pulumi — flag-prefixed variants (e.g. "pulumi -C infra up")
# Strip -C / --cwd and other global flags, then match effective subcommand.
# ---------------------------------------------------------------------------
PULUMI_SEG_FOUND=0
for segment in "${SEGMENTS[@]}"; do
    if echo "$segment" | grep -qE '^\s*pulumi\s'; then
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

    for segment in "${SEGMENTS[@]}"; do
        # Only consider segments that begin with `pulumi`.
        echo "$segment" | grep -qE '^\s*pulumi\s' || continue
        EFFECTIVE=$(echo "$segment" \
            | sed 's/^\s*pulumi\s\+//' \
            | sed 's/-C\s\+[^ ]\+\s*//g' \
            | sed 's/--cwd\s\+[^ ]\+\s*//g' \
            | sed 's/-s\s\+[^ ]\+\s*//g' \
            | sed 's/--stack\s\+[^ ]\+\s*//g' \
            | sed 's/--color\s\+[^ ]\+\s*//g' \
            | sed 's/-v\s\+[^ ]\+\s*//g' \
            | sed 's/--verbose\s\+[^ ]\+\s*//g' \
            | sed 's/--[a-z-]*\s*//g' \
            | sed 's/\s\+/ /g' \
            | sed 's/^\s*//')
        for subcmd in "${PULUMI_WRITE_SUBCMDS[@]}"; do
            if echo "$EFFECTIVE" | grep -qE "^${subcmd}(\s|$)"; then
                ask "pulumi command requires confirmation."
            fi
        done
    done
fi

exit 0

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

# Transcript path from the hook payload — passed to notify_user_attention on the
# ask path so the tab stays BLUE (not green) while a background agent/task or CI
# is still running. Captured here at top level so it is in scope inside ask().
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$COMMAND" ] || exit 0

ask() {
    local reason="$1"
    # Ping the user before emitting the "ask" decision: plays a chime, turns
    # the iTerm2 tab green, and sets a "waiting..." terminal title so the user
    # notices the pending confirmation prompt even if they're away from the
    # screen. Sourced lazily (only on the ask path) so allow/deny paths stay
    # silent. notify_user_attention writes to the user's tty (not stdout), so
    # this is safe to call before the JSON decision is printed below.
    source /Users/yonichechik/.claude/scripts/_notify.sh
    notify_user_attention "$TRANSCRIPT"
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
            # Custom message for `gh pr merge` so the user is reminded that
            # any prior in-session authorization may have gone stale.
            if [ "$pattern" = "gh pr merge" ]; then
                ask "gh pr merge — confirm authorization is fresh (do not assume prior approval still applies)."
            fi
            ask "gh command requires confirmation."
        fi
    done
done

# ---------------------------------------------------------------------------
# HTTP mutation against sunsay-ltd GitHub repos
# Closes the bypass where curl/wget/http/xh with -X PUT/POST/PATCH/DELETE
# was used to hit api.github.com/repos/sunsay-ltd/... directly (e.g.
# merging a PR via the REST API when `gh pr merge` is gated).
# ---------------------------------------------------------------------------
for segment in "${SEGMENTS[@]}"; do
    if [[ "$segment" =~ (^|[[:space:]])(curl|wget|http|xh)([[:space:]]) ]] && \
       [[ "$segment" =~ (-X[[:space:]]+(POST|PUT|PATCH|DELETE)|--request[[:space:]]+(POST|PUT|PATCH|DELETE)) ]] && \
       [[ "$segment" =~ api\.github\.com/repos/sunsay-ltd ]]; then
        deny "Blocked: HTTP mutation (POST/PUT/PATCH/DELETE) against api.github.com/repos/sunsay-ltd. Use the gh CLI with explicit user approval — do not bypass via raw HTTP."
    fi
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
# gcloud run — hard-deny revision-creating verbs against prod-like projects.
# `gcloud run services update|replace|deploy|create` and bare `gcloud run
# deploy` create a new active revision and can take down production traffic
# (e.g. by pointing at a broken image or stale env). Must be run manually.
# ---------------------------------------------------------------------------
GCLOUD_RUN_PROTECTED_PROJECTS='(production-490411|staging-480220|mirror-production-496017)'
for segment in "${SEGMENTS[@]}"; do
    if [[ "$segment" =~ gcloud[[:space:]]+run[[:space:]]+(services[[:space:]]+(update|replace|deploy|create)|deploy)([[:space:]]|$) ]] && \
       [[ "$segment" =~ --project[[:space:]]*=?[[:space:]]*${GCLOUD_RUN_PROTECTED_PROJECTS} ]]; then
        deny "Blocked: gcloud run revision-creating verb (update/replace/deploy/create) against a protected project (production-490411 / staging-480220 / mirror-production-496017). Requires explicit user execution — do not retry."
    fi
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
# --- target detection helpers -----------------------------------------------
# Several supabase subcommands run against EITHER the local dev database (the
# docker Postgres started by `supabase start`) or a remote one. The CLI picks
# the target from these mutually-exclusive flags (see supabase/cli
# internal/utils/flags/db_url.go, ParseDatabaseConfig):
#   --linked          -> the linked cloud project (REMOTE, destructive)
#   --proxy           -> the same cloud project, tunnelled via the Supabase API
#   --db-url <conn>   -> an arbitrary connection string (remote UNLESS its host
#                        is loopback, e.g. the local supabase container)
#   --local           -> the local dev database (safe)
# An explicitly-passed flag always wins over the subcommand's default value,
# and passing `--linked=false` still selects the linked path in the CLI, so any
# occurrence of the `--linked` token counts as remote here.
# Note: `--project-ref` alone does NOT redirect the db target (it only names
# which project `--linked` would resolve to), so it is not a remote signal.

# Strips characters that would break the printf-built JSON of ask()/deny()
# (double quotes, backslashes, percent signs) out of interpolated text.
supabase_json_safe() {
    echo "$1" | tr -d '"\\%' | tr -d '\n'
}

# Echoes the raw connection string that follows --db-url, or nothing when the
# flag is absent. Handles `--db-url X`, `--db-url=X` and quoted values.
supabase_db_url_value() {
    echo "$1" | sed -nE "s/.*--db-url[[:space:]=]+[\"']?([^\"'[:space:]]+).*/\1/p"
}

# Echoes the host part of the --db-url value: drops scheme, drops user:pass@,
# drops path/query, drops :port, unwraps [::1]-style IPv6 brackets.
supabase_db_url_host() {
    echo "$1" | sed -E 's#^[a-zA-Z0-9+.-]+://##; s#^[^@/]*@##; s#[/?].*$##; s#:[0-9]+$##; s#^\[(.*)\]$#\1#'
}

# True when the --db-url host is loopback, i.e. the local dev database. A value
# we cannot resolve (e.g. "$DATABASE_URL") is NOT loopback -> treated as remote.
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

# True when ANY target-selecting flag is present. Drives the "bare call" branch
# of the three-way policy below: no flag at all means the agent never stated its
# intent, so the guard denies instead of trusting the CLI's implicit default.
supabase_has_target_flag() {
    echo "$1" | grep -qE '(^|\s)--(local|linked|proxy|db-url)(=|\s|$)'
}

# True when the segment explicitly aims at the local dev database.
supabase_targets_local() {
    local seg="$1"
    echo "$seg" | grep -qE '(^|\s)--local(=|\s|$)' && return 0
    if echo "$seg" | grep -qE '(^|\s)--db-url(=|\s)'; then
        supabase_db_url_is_local "$seg" && return 0
    fi
    return 1
}

# Echoes a human phrase that names the remote target the segment implies, so the
# confirmation prompt says WHAT gets hit instead of just "a remote database".
supabase_remote_detail() {
    local seg="$1" url host
    if echo "$seg" | grep -qE '(^|\s)--linked(=|\s|$)'; then
        echo "--linked targets the linked cloud project"
        return
    fi
    if echo "$seg" | grep -qE '(^|\s)--proxy(=|\s|$)'; then
        echo "--proxy targets the linked cloud project through the Supabase API"
        return
    fi
    url=$(supabase_db_url_value "$seg")
    host=$(supabase_db_url_host "$url")
    if [ -n "$host" ] && echo "$host" | grep -qE '^[A-Za-z0-9._-]+$'; then
        echo "--db-url targets the DB at $(supabase_json_safe "$host")"
    else
        # Unresolvable value (shell variable, etc.) — a flag IS present, so this
        # stays an ask, never a deny; the guard just cannot name the host.
        echo "--db-url targets an unresolved remote DB ($(supabase_json_safe "$url"))"
    fi
}

# --- pattern lists ----------------------------------------------------------
# 1) Always remote / always destructive: ask unconditionally. These take no
#    local/remote target flags, so the three-way policy does not apply to them.
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

# 2) Target-aware subcommands: each one accepts --local / --linked / --db-url,
#    so the same command is either harmless dev-loop work or a remote mutation.
#    The CLI's own defaults differ per subcommand (db reset / migration up /
#    migration down / migration squash default to --local; db push and
#    migration repair default to --linked), which makes a bare call ambiguous
#    to read. The guard therefore ignores those defaults completely and applies
#    ONE three-way policy to every pattern below:
#      a) no target flag at all  -> deny; the agent must state its intent.
#      b) --local or loopback --db-url -> allow silently, no prompt.
#      c) --linked / --proxy / non-loopback or unresolvable --db-url -> ask,
#         naming the remote target in the prompt.
SUPABASE_TARGET_AWARE_PATTERNS=(
    "supabase db reset"
    "supabase migration up"
    "supabase migration down"
    "supabase migration squash"
    "supabase db push"
    "supabase migration repair"
)

for pattern in "${SUPABASE_PATTERNS[@]}"; do
    for segment in "${SEGMENTS[@]}"; do
        if echo "$segment" | grep -qE "^${pattern}(\s|$)"; then
            ask "supabase command requires confirmation."
        fi
    done
done

for pattern in "${SUPABASE_TARGET_AWARE_PATTERNS[@]}"; do
    for segment in "${SEGMENTS[@]}"; do
        echo "$segment" | grep -qE "^${pattern}(\s|$)" || continue

        # (b) Explicitly local — the safe dev-loop path, no prompt.
        if supabase_targets_local "$segment"; then
            continue
        fi

        # (a) Bare call — no target flag, so the effective database depends on a
        #     per-subcommand CLI default. Refuse rather than guess.
        if ! supabase_has_target_flag "$segment"; then
            deny "Blocked: \`${pattern}\` needs an explicit target — add --local to hit the local dev DB, or --linked/--db-url <remote> to target remote (remote will then require confirmation)."
        fi

        # (c) A remote target is named — ask, and say which one.
        ask "\`${pattern}\` $(supabase_remote_detail "$segment") — confirm this is intended."
    done
done

# ---------------------------------------------------------------------------
# pulumi — hard-deny prod-stack mutations without a tight, valid --target set.
# Must run BEFORE the generic pulumi ask-loops below: those exit on `ask`,
# which would short-circuit this stricter deny check.
#
# Applies to `pulumi up`, `pulumi destroy`, `pulumi cancel` against
# --stack production / prod / mirror / main. The intent: a model can never
# blast a full prod stack — it must enumerate specific resource URNs, and
# only a few of them. Bypass shapes we explicitly reject:
#   - No --target at all (would target the whole stack).
#   - --target-dependents (walks the dependency graph; effectively whole-stack).
#   - --target pointing at the Stack root URN (whole-stack via root).
#   - More than 5 --target flags (heuristic: enumerate-everything bypass).
#   - Any --target value that isn't shaped like a fully-qualified resource URN.
# ---------------------------------------------------------------------------
pulumi_target_guard() {
    local seg="$1"

    # Subcommand check. We strip the leading `pulumi` and any -C / --cwd
    # global flags (so "pulumi -C infra/core up ..." still matches "up").
    # Uses sed -E with POSIX character classes for BSD-sed (macOS) compat.
    local stripped
    stripped=$(echo "$seg" \
        | sed -E 's/^[[:space:]]*pulumi[[:space:]]+//' \
        | sed -E 's/-C[[:space:]]+[^ ]+[[:space:]]*//g' \
        | sed -E 's/--cwd[[:space:]]+[^ ]+[[:space:]]*//g' \
        | sed -E 's/^[[:space:]]+//')
    [[ "$stripped" =~ ^(up|destroy|cancel)([[:space:]]|$) ]] || return 0

    # Stack check — match both `--stack X`, `--stack=X`, `-s X`, `-s=X`.
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

    # Reject --target-dependents (graph-walk bypass).
    if [[ "$seg" =~ (^|[[:space:]])--target-dependents([[:space:]]|=|$) ]]; then
        deny "${block_prefix} --target-dependents walks the dependency graph and is effectively whole-stack. Run manually."
    fi

    # Collect every --target / -t value (both `--target X` and `--target=X`).
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

    # Reject if no --target flags at all.
    if [ ${#targets[@]} -eq 0 ]; then
        deny "${block_prefix} No --target specified — would mutate the entire stack. Pulumi against prod-like stacks must enumerate specific resource URNs."
    fi

    # Heuristic: >5 targets suggests enumerate-everything bypass.
    if [ ${#targets[@]} -gt 5 ]; then
        deny "${block_prefix} More than 5 --target flags (${#targets[@]}); this looks like enumerate-all-URNs. Split into smaller manual runs."
    fi

    # Per-target validation.
    local t
    for t in "${targets[@]}"; do
        # Strip surrounding quotes if any.
        t="${t%\"}"; t="${t#\"}"
        t="${t%\'}"; t="${t#\'}"

        # Reject Stack-root URN (whole-stack via root).
        if [[ "$t" =~ ^urn:pulumi:[^:]+::[^:]+::pulumi:pulumi:Stack:: ]]; then
            deny "${block_prefix} --target points at the Stack root URN ($t) — equivalent to whole-stack. Target individual resources instead."
        fi

        # Must look like a fully-qualified resource URN:
        #   urn:pulumi:<stack>::<project>::<type>::<name>
        # Note: <type> itself contains colons (e.g.
        # `gcp:cloudrunv2/service:Service`), so we allow `.+` for it and pin
        # the tail with `::<no-colon-name>$`.
        if ! [[ "$t" =~ ^urn:pulumi:[^:]+::[^:]+::.+::[^:]+$ ]]; then
            deny "${block_prefix} --target value '$t' is not a fully-qualified resource URN (urn:pulumi:<stack>::<project>::<type>::<name>). Refusing to guess."
        fi
    done
}

for segment in "${SEGMENTS[@]}"; do
    echo "$segment" | grep -qE '^\s*pulumi\s' || continue
    pulumi_target_guard "$segment"
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

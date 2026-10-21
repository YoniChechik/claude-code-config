#!/usr/bin/env bats

setup() {
    HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/pre_tool_use__permission_guard.sh"

    GH="g""h"
    REPO="rep""o"
    DEL="del""ete"
    GC="gclo""ud"
    INST="comp""ute"
    INSTANCES="instanc""es"

    unset SUPABASE_PROJECT_ID SUPABASE_WORKDIR PULUMI_STACK PULUMI_BACKEND_URL CLAUDE_STATE_DIR
    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
    export PULUMI_HOME="$BATS_TEST_TMPDIR/pulumi_home"
    mkdir -p "$PULUMI_HOME/workspaces"

    PROD_REF=pnseoblfzeqiczmmimnr
    PROD_REF2=ampdktckxcbdajezxkul
    STG_REF=zgxsvuxflvxioxhhjutj
    STG_REF2=rikdpqmmvlmzrgravwep

    SB_PROD="$BATS_TEST_TMPDIR/app"
    SB_PROD2="$BATS_TEST_TMPDIR/backoffice"
    SB_STG="$BATS_TEST_TMPDIR/staging"
    NOWHERE="$BATS_TEST_TMPDIR/nowhere"
    mkdir -p "$SB_PROD/supabase/.temp" "$SB_PROD/apps/web" "$SB_PROD2/supabase/.temp" "$SB_STG/supabase/.temp" "$NOWHERE"
    printf '%s\n' "$PROD_REF" >"$SB_PROD/supabase/.temp/project-ref"
    printf '%s\n' "$PROD_REF2" >"$SB_PROD2/supabase/.temp/project-ref"
    printf '%s\n' "$STG_REF" >"$SB_STG/supabase/.temp/project-ref"

    PU_PROD="$BATS_TEST_TMPDIR/infra_prod"
    PU_STG="$BATS_TEST_TMPDIR/infra_stg"
    PU_NONE="$BATS_TEST_TMPDIR/infra_none"
    make_pulumi_project "$PU_PROD" core '{"stack":"organization/core/production"}'
    make_pulumi_project "$PU_STG" core '{"stack":"organization/core/staging"}'
    make_pulumi_project "$PU_NONE" core ""
}

make_pulumi_project() {
    mkdir -p "$1"
    printf 'name: %s\nruntime: nodejs\n' "$2" >"$1/Pulumi.yaml"
    if [ -n "${4:-}" ]; then
        printf 'backend:\n  url: %s\n' "$4" >>"$1/Pulumi.yaml"
    fi
    if [ -n "$3" ]; then
        local hash
        hash=$(printf '%s' "$1/Pulumi.yaml" | shasum -a 1 | cut -d' ' -f1)
        printf '%s' "$3" >"$PULUMI_HOME/workspaces/$2-$hash-workspace.json"
    fi
}

decide_in() {
    local out
    out=$(jq -nc --arg cwd "$1" --arg cmd "$2" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' | bash "$HOOK")
    if [ -z "$out" ]; then
        echo "NONE"
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z'
    fi
}

decide() {
    decide_in "$NOWHERE" "$1"
}

decide_reason() {
    jq -nc --arg cwd "$NOWHERE" --arg cmd "$1" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' | bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason'
}

assert_decision() {
    if [ "$1" != "$2" ]; then
        echo "expected=$1 got=$2" >&2
        return 1
    fi
}

@test "none: gh pr list is unaffected" {
    assert_decision NONE "$(decide "$GH pr list")"
}

@test "none: gcloud compute instances list is unaffected" {
    assert_decision NONE "$(decide "$GC $INST $INSTANCES list")"
}

@test "none: a commit message merely mentioning the phrase is not a command" {
    assert_decision NONE "$(decide "git commit -m \"note about $GH $REPO $DEL risk\"")"
}

@test "none: bq query (not rm/truncate) is unaffected" {
    assert_decision NONE "$(decide "bq query 'select 1'")"
}

@test "deny: gcloud projects delete" {
    assert_decision DENY "$(decide "$GC projects $DEL my-project")"
    assert_decision DENY "$(decide "cd /tmp && $GC projects $DEL my-project --quiet")"
}

@test "none: gh run cancel, gcloud storage rm and bq rm are allowed" {
    assert_decision NONE "$(decide "$GH run cancel 1")"
    assert_decision NONE "$(decide "$GC storage rm gs://b/x")"
    assert_decision NONE "$(decide "bq rm mydataset.mytable")"
}

@test "none: gcloud run deploy against an unprotected project is allowed" {
    assert_decision NONE "$(decide "$GC run deploy svc --project dev-123")"
    assert_decision DENY "$(decide "$GC run deploy svc --project staging-480220")"
}

@test "deny: gh repo delete, direct" {
    assert_decision DENY "$(decide "$GH $REPO $DEL foo/bar")"
}

@test "none: gh repo archive is allowed" {
    assert_decision NONE "$(decide "$GH repo archive foo/bar")"
}

@test "none: gcloud compute instances delete is allowed" {
    assert_decision NONE "$(decide "$GC $INST instances $DEL x")"
}

@test "deny: cd foo then gh repo delete (segment split)" {
    assert_decision DENY "$(decide "cd foo && $GH $REPO $DEL foo/bar")"
}

@test "deny: command substitution assigned to a variable, \$(...)" {
    assert_decision DENY "$(decide "X=\$($GH $REPO $DEL foo/bar)")"
}

@test "deny: eval with a double-quoted destructive command" {
    assert_decision DENY "$(decide "eval \"$GH $REPO $DEL foo/bar\"")"
}

@test "deny: eval with a single-quoted destructive command" {
    assert_decision DENY "$(decide "eval '$GH $REPO $DEL foo/bar'")"
}

@test "deny: bash -c wrapping a destructive command" {
    assert_decision DENY "$(decide "bash -c \"$GH $REPO $DEL foo/bar\"")"
}

@test "none: a backtick substitution of a gcloud delete is allowed" {
    assert_decision NONE "$(decide "X=\`$GC $INST instances $DEL x\`")"
}

@test "deny: \`command\` builtin prefix" {
    assert_decision DENY "$(decide "command $GH $REPO $DEL foo/bar")"
}

@test "none: \`command\` builtin prefix on a gcloud delete is allowed" {
    assert_decision NONE "$(decide "command $GC $INST instances $DEL x")"
}

@test "deny: backslash-escaped leading command word" {
    assert_decision DENY "$(decide "\\$GH $REPO $DEL foo/bar")"
}

@test "none: bare VAR=value env-prefix before a gcloud delete is allowed" {
    assert_decision NONE "$(decide "FOO=bar $GC $INST instances $DEL x")"
}

@test "deny: \`env\` builtin prefix" {
    assert_decision DENY "$(decide "env $GH $REPO $DEL foo/bar")"
}

@test "deny: nested command substitution inside a double-quoted string" {
    assert_decision DENY "$(decide "echo \"result: \$($GH $REPO $DEL foo/bar)\"")"
}

@test "none: pulumi -C flag-prefixed destructive subcommand with no resolvable stack" {
    assert_decision NONE "$(decide "pulumi -C infra up")"
}

@test "deny: bash -c with trailing argv after the code string" {
    assert_decision DENY "$(decide "bash -c \"$GH $REPO $DEL foo/bar\" sentinel")"
}

@test "deny: bash -lc with combined short flags" {
    assert_decision DENY "$(decide "bash -lc \"$GH $REPO $DEL foo/bar\"")"
}

@test "deny: sh -ic with combined short flags" {
    assert_decision DENY "$(decide "sh -ic '$GH $REPO $DEL foo/bar'")"
}

@test "deny: an absolute path to the interpreter" {
    assert_decision DENY "$(decide "/bin/bash -c \"$GH $REPO $DEL foo/bar\"")"
}

@test "deny: quote concatenation inside the command word" {
    assert_decision DENY "$(decide "g\"h\" $REPO $DEL foo/bar")"
}

@test "deny: quote concatenation inside a subcommand word" {
    assert_decision DENY "$(decide "$GH re\"\"po $DEL foo/bar")"
}

@test "deny: single-quote concatenation inside the command word" {
    assert_decision DENY "$(decide "g'h' $REPO $DEL foo/bar")"
}

@test "deny: an absolute path to the gh binary" {
    assert_decision DENY "$(decide "/usr/bin/$GH $REPO $DEL foo/bar")"
}

@test "deny: a relative path to the gh binary" {
    assert_decision DENY "$(decide "./bin/$GH $REPO $DEL foo/bar")"
}

@test "deny: env with an argument-taking flag before the real command" {
    assert_decision DENY "$(decide "env -u FOO $GH $REPO $DEL foo/bar")"
}

@test "deny: env -i with an assignment before the real command" {
    assert_decision DENY "$(decide "env -i PATH=/usr/bin $GH $REPO $DEL foo/bar")"
}

@test "deny: builtin wrapper prefix" {
    assert_decision DENY "$(decide "builtin command $GH $REPO $DEL foo/bar")"
}

@test "deny: exec wrapper prefix" {
    assert_decision DENY "$(decide "exec $GH $REPO $DEL foo/bar")"
}

@test "deny: brace group" {
    assert_decision DENY "$(decide "{ $GH $REPO $DEL foo/bar; }")"
}

@test "deny: if/then construct" {
    assert_decision DENY "$(decide "if true; then $GH $REPO $DEL foo/bar; fi")"
}

@test "deny: if/else construct, destructive command in the else body" {
    assert_decision DENY "$(decide "if false; then echo no; else $GH $REPO $DEL foo/bar; fi")"
}

@test "deny: while/do construct" {
    assert_decision DENY "$(decide "while true; do $GH $REPO $DEL foo/bar; done")"
}

@test "deny: for/do construct" {
    assert_decision DENY "$(decide "for i in 1 2; do $GH $REPO $DEL foo/bar; done")"
}

@test "deny: subshell grouping" {
    assert_decision DENY "$(decide "( $GH $REPO $DEL foo/bar )")"
}

@test "none: a grammar-wrapped gcloud delete is allowed" {
    assert_decision NONE "$(decide "{ $GC $INST $INSTANCES $DEL x; }")"
}

@test "deny: allowed gcloud command first, gcloud-run prod deny-rule second" {
    local cmd="$GC $INST $INSTANCES $DEL x && $GC run deploy --project=production-490411"
    assert_decision DENY "$(decide "$cmd")"
}

@test "deny: allowed bq command first, pulumi prod deny-rule second" {
    assert_decision DENY "$(decide "bq rm mydataset.mytable && pulumi up --stack production")"
}

@test "deny: allowed gh command first, gh repo delete deny-rule later in the same command" {
    assert_decision DENY "$(decide "$GH repo archive foo/bar && $GH $REPO $DEL foo/bar")"
}

@test "deny: allowed gh command first, supabase prod deny-rule second" {
    assert_decision DENY "$(decide "$GH repo archive foo/bar && supabase functions deploy x --project-ref $PROD_REF")"
}

@test "none: a compound of allowed gh commands is allowed (deny is never invented)" {
    assert_decision NONE "$(decide "$GH repo archive foo/bar && $GH repo rename baz")"
}

@test "deny: a broken shared library fails closed instead of silently allowing" {
    local dir="$BATS_TEST_TMPDIR/brokenlib"
    mkdir -p "$dir"
    cp "$HOOK" "$dir/"
    local out
    out=$(jq -nc --arg cmd "$GH $REPO $DEL foo/bar" '{tool_name:"Bash",tool_input:{command:$cmd}}' \
        | bash "$dir/$(basename "$HOOK")")
    [ -n "$out" ]
    assert_decision DENY "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z')"
}

@test "supabase: --db-url beats --local, so db reset --local --db-url <prod> is denied" {
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase db reset --local --db-url postgresql://postgres:pw@db.$PROD_REF.supabase.co:5432/postgres")"
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase db reset --db-url=postgresql://postgres.$PROD_REF2:pw@aws-0-eu-central-1.pooler.supabase.com:6543/postgres --local")"
}

@test "supabase: npx db push in a prod-linked dir is denied, staging is allowed" {
    assert_decision DENY "$(decide_in "$SB_PROD" "npx supabase db push")"
    assert_decision DENY "$(decide_in "$SB_PROD2" "npx supabase db push")"
    assert_decision NONE "$(decide_in "$SB_STG" "npx supabase db push")"
}

@test "supabase: wrapper runners resolve to the real subcommand" {
    assert_decision DENY "$(decide_in "$SB_PROD" "pnpm exec supabase db push")"
    assert_decision DENY "$(decide_in "$SB_PROD" "pnpm dlx supabase db push")"
    assert_decision DENY "$(decide_in "$SB_PROD" "bunx supabase db push")"
    assert_decision DENY "$(decide_in "$SB_PROD" "npx -y supabase@2.84.2 db push")"
    assert_decision NONE "$(decide_in "$SB_PROD" "npx supabase db reset")"
}

@test "supabase: project ref is found by walking up from a subdirectory" {
    assert_decision DENY "$(decide_in "$SB_PROD/apps/web" "supabase db push")"
}

@test "supabase: bare default-local commands are allowed even in a prod-linked dir" {
    for c in "db reset" "migration up" "migration down" "migration squash" "db diff" "db lint" "db query" "seed buckets" "test db"; do
        assert_decision NONE "$(decide_in "$SB_PROD" "supabase $c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "supabase: always-local commands are allowed (stop and link included)" {
    for c in "start" "stop" "status" "init" "functions serve" "migration new add_table" "link --project-ref $PROD_REF"; do
        assert_decision NONE "$(decide_in "$SB_PROD" "supabase $c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "supabase: global flags before the subcommand (--experimental db reset --linked)" {
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase --experimental db reset --linked")"
    assert_decision NONE "$(decide_in "$SB_STG" "supabase --experimental db reset --linked")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase --experimental db reset --local")"
}

@test "supabase: default-local commands targeting remote via --linked follow the ref" {
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase migration up --linked")"
    assert_decision NONE "$(decide_in "$SB_STG" "supabase db diff --linked")"
    assert_decision NONE "$(decide_in "$SB_STG" "supabase db reset --linked")"
    assert_decision NONE "$(decide_in "$NOWHERE" "supabase db reset --linked")"
}

@test "supabase: target precedence --db-url > --local > --linked" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --linked --db-url postgresql://postgres:postgres@127.0.0.1:54322/postgres")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --linked --local")"
}

@test "supabase: default-linked commands with no flag are remote" {
    for c in "migration repair 2024 --status applied" "migration list" "migration fetch" "db dump" "db pull" "storage rm ss:///b/x" "storage cp a ss:///b/a" "storage mv ss:///b/a ss:///b/c" "inspect db bloat"; do
        assert_decision DENY "$(decide_in "$SB_PROD" "supabase $c")" || { echo "cmd: $c" >&2; return 1; }
    done
    assert_decision NONE "$(decide_in "$SB_STG" "supabase migration repair 2024 --status applied")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase storage ls --local")"
}

@test "supabase: unresolvable ref on a remote command is allowed" {
    assert_decision NONE "$(decide_in "$NOWHERE" "supabase db push")"
    assert_decision NONE "$(decide_in "$NOWHERE" "supabase functions deploy fn")"
    assert_decision NONE "$(decide_in "$NOWHERE" "supabase db push --project-ref \$REF")"
}

@test "supabase: cd X && is honored for the ref lookup" {
    assert_decision DENY "$(decide_in "$NOWHERE" "cd $SB_PROD && supabase db push")"
    assert_decision NONE "$(decide_in "$SB_PROD" "cd $SB_STG && supabase db push")"
}

@test "supabase: --workdir, --workdir= and SUPABASE_WORKDIR are honored" {
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase db push --workdir $SB_PROD")"
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase --workdir=$SB_PROD db push")"
    assert_decision DENY "$(decide_in "$NOWHERE" "SUPABASE_WORKDIR=$SB_PROD supabase db push")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --workdir $SB_STG")"
}

@test "supabase: SUPABASE_PROJECT_ID beats the linked project-ref file" {
    assert_decision DENY "$(decide_in "$SB_STG" "SUPABASE_PROJECT_ID=$PROD_REF supabase db push")"
    assert_decision NONE "$(decide_in "$SB_PROD" "SUPABASE_PROJECT_ID=$STG_REF2 supabase db push")"
    assert_decision DENY "$(SUPABASE_PROJECT_ID=$PROD_REF decide_in "$NOWHERE" "supabase db push")"
}

@test "supabase: API-only commands follow --project-ref, then the linked ref" {
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase functions deploy fn --project-ref $PROD_REF")"
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase functions delete fn --project-ref=$PROD_REF2")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase functions deploy fn --project-ref $STG_REF")"
    assert_decision NONE "$(decide_in "$NOWHERE" "supabase secrets set --project-ref \$REF A=b")"
    for c in "secrets set A=b" "secrets unset A" "config push" "branches create x" "branches delete x" "postgres-config update --config x=y" "backups restore --timestamp 1" "domains create" "sso add" "network-restrictions update" "network-bans remove" "ssl-enforcement update --enable-db-ssl-enforcement"; do
        assert_decision DENY "$(decide_in "$SB_PROD" "supabase $c")" || { echo "cmd: $c" >&2; return 1; }
        assert_decision NONE "$(decide_in "$SB_STG" "supabase $c")" || { echo "cmd: $c (staging)" >&2; return 1; }
    done
}

@test "supabase: projects delete uses its positional ref" {
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase projects delete $PROD_REF")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase projects delete $STG_REF")"
}

@test "supabase: --dry-run only allows subcommands that implement it" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --dry-run")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db dump --dry-run")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase functions deploy fn --dry-run")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase migration repair 1 --status applied --dry-run")"
}

@test "supabase: gen types follows --project-id/--linked, otherwise it is allowed" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase gen types typescript --local")"
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase gen types typescript --project-id $PROD_REF")"
    assert_decision NONE "$(decide_in "$NOWHERE" "supabase gen types typescript --project-id $STG_REF")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase gen types typescript --linked")"
    assert_decision NONE "$(decide_in "$SB_STG" "supabase gen types typescript")"
}

@test "supabase: --db-url only denies production URLs" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --db-url postgresql://postgres:postgres@127.0.0.1:54322/postgres")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --db-url 'postgresql://postgres:postgres@localhost:54322/postgres'")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --db-url postgresql://u:p@db.$STG_REF.supabase.co:5432/postgres")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db dump --db-url postgresql://u:p@db.$STG_REF.supabase.co:5432/postgres")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --db-url \"\$DATABASE_URL\"")"
}

@test "supabase: a nested bash -c inherits the cwd context" {
    assert_decision DENY "$(decide_in "$SB_PROD" "bash -c \"supabase db push\"")"
}

@test "supabase: read-only and unrelated subcommands have no opinion" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase projects list")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase --version")"
}

@test "pulumi: a fully-qualified prod stack is denied" {
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi up -s organization/x/production")"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi up --stack=organization/x/prod")"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi destroy -sorganization/x/main")"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi up --stack mirror --yes")"
}

@test "pulumi: bare up with prod selected in the workspace is denied" {
    assert_decision DENY "$(decide_in "$PU_PROD" "pulumi up")"
    assert_decision DENY "$(decide_in "$PU_PROD" "pulumi up --yes --skip-preview")"
}

@test "pulumi: workspace with a per-backend stacks map" {
    local dir="$BATS_TEST_TMPDIR/infra_map"
    make_pulumi_project "$dir" mapproj '{"stacks":{"https://api.pulumi.com":"organization/mapproj/production"}}'
    assert_decision DENY "$(decide_in "$dir" "pulumi up")"
}

@test "pulumi: non-prod and unresolvable stacks are allowed" {
    assert_decision NONE "$(decide_in "$PU_STG" "pulumi up")"
    assert_decision NONE "$(decide_in "$PU_NONE" "pulumi up -s \$STACK")"
    assert_decision NONE "$(decide_in "$PU_NONE" "pulumi up")"
    assert_decision NONE "$(decide_in "$PU_NONE" "pulumi up -s organization/x/staging")"
}

@test "pulumi: stack names are matched on the exact last segment, never by substring" {
    for s in domain-staging remain organization/x/production-copy prod-eu organization/main/dev; do
        assert_decision NONE "$(decide_in "$PU_NONE" "pulumi up -s $s")" || { echo "stack: $s" >&2; return 1; }
    done
}

@test "pulumi: PULUMI_STACK prefix and environment select the stack" {
    assert_decision DENY "$(decide_in "$PU_STG" "PULUMI_STACK=organization/core/production pulumi up")"
    assert_decision NONE "$(decide_in "$PU_PROD" "PULUMI_STACK=organization/core/dev pulumi up")"
    assert_decision DENY "$(PULUMI_STACK=prod decide_in "$PU_NONE" "pulumi up")"
}

@test "pulumi: -C, --cwd= and cd X && locate the workspace" {
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi -C $PU_PROD up")"
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi up --cwd=$PU_PROD")"
    assert_decision DENY "$(decide_in "$NOWHERE" "cd $PU_PROD && pulumi up")"
    assert_decision NONE "$(decide_in "$PU_PROD" "cd $PU_STG && pulumi up")"
}

@test "pulumi: preview, --preview-only and read-only commands are allowed" {
    for c in "preview" "refresh --preview-only" "destroy --preview-only" "import --preview-only aws:s3/bucket:Bucket b id" "stack ls" "stack output" "config get key" "stack select organization/core/production" "login --local" "whoami"; do
        assert_decision NONE "$(decide_in "$PU_PROD" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "pulumi: file:// backend skips only the backend-URL check, prod stack names are still denied" {
    local dir="$BATS_TEST_TMPDIR/infra_file" devdir="$BATS_TEST_TMPDIR/infra_file_dev" nodir="$BATS_TEST_TMPDIR/infra_file_none"
    make_pulumi_project "$dir" fileproj '{"stack":"production"}' "file://~/production-state"
    make_pulumi_project "$devdir" filedev '{"stack":"dev"}' "file://~/production-state"
    make_pulumi_project "$nodir" filenone "" "file://~/state"
    assert_decision DENY "$(decide_in "$dir" "pulumi up")"
    assert_decision DENY "$(decide_in "$PU_NONE" "PULUMI_BACKEND_URL=file:///tmp/state pulumi up -s organization/x/production")"
    assert_decision DENY "$(decide_in "$PU_PROD" "PULUMI_BACKEND_URL=file:///tmp/state pulumi up")"
    assert_decision DENY "$(decide_in "$devdir" "pulumi destroy -s main")"
    assert_decision DENY "$(decide_in "$devdir" "pulumi refresh -s prod")"
    assert_decision NONE "$(decide_in "$devdir" "pulumi up")"
    assert_decision NONE "$(decide_in "$PU_STG" "PULUMI_BACKEND_URL=file:///tmp/state pulumi up")"
    assert_decision NONE "$(decide_in "$nodir" "pulumi up")"
    assert_decision DENY "$(decide_in "$PU_STG" "PULUMI_BACKEND_URL=gs://production-pulumi-state pulumi up")"
}

@test "pulumi: deployment runs and settings changes follow the resolved stack" {
    for c in "deployment run up" "deployment run destroy" "deployment settings configure" "deployment settings destroy" "deployment settings push"; do
        assert_decision DENY "$(decide_in "$PU_PROD" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
        assert_decision NONE "$(decide_in "$PU_STG" "pulumi $c")" || { echo "cmd: $c (staging)" >&2; return 1; }
    done
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi deployment run up -s organization/core/production")"
    assert_decision NONE "$(decide_in "$PU_PROD" "pulumi deployment settings pull")"
}

@test "pulumi: org-wide policy changes and local project commands are allowed" {
    for c in "policy publish org" "policy enable org/pack latest" "policy disable org/pack" "policy rm org/pack 1"; do
        assert_decision NONE "$(decide_in "$PU_NONE" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
    done
    for c in "new gcp-typescript --yes" "plugin install resource gcp" "policy ls" "policy new aws-typescript" "stack init organization/core/dev" "login gs://bucket"; do
        assert_decision NONE "$(decide_in "$PU_PROD" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "pulumi: the mutating set follows the resolved stack" {
    for c in "destroy" "refresh" "import aws:s3/bucket:Bucket b id" "cancel" "watch" "state delete urn:x" "state rename urn:x y" "state move --dest organization/core/dev urn:x" "state unprotect urn:x" "state protect urn:x" "state repair" "state taint urn:x" "state untaint urn:x" "state upgrade" "stack rm" "stack rename organization/core/next" "stack import --file x.json" "stack tag set k v" "stack tag rm k" "stack change-secrets-provider passphrase" "config set k v" "config set-all --plaintext k=v" "config rm k" "config rm-all k" "config cp --dest organization/core/dev" "config refresh"; do
        assert_decision DENY "$(decide_in "$PU_PROD" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
        assert_decision NONE "$(decide_in "$PU_STG" "pulumi $c")" || { echo "cmd: $c (staging)" >&2; return 1; }
    done
}

@test "pulumi: stack-name positionals and move/copy destinations are checked" {
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi stack rm organization/core/production --yes")"
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi stack select --create organization/core/prod")"
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi stack rename organization/core/production")"
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi state move --source organization/core/dev --dest organization/core/production urn:x")"
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi config cp -d organization/core/production")"
    assert_decision NONE "$(decide_in "$PU_STG" "pulumi stack select -c organization/core/dev2")"
}

@test "pulumi: ESC environment mutations follow the environment name" {
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi env set organization/core/production key value")"
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi env rm organization/core/prod")"
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi env clone organization/core/dev organization/core/production")"
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi env version tag organization/core/production@3 stable")"
    assert_decision NONE "$(decide_in "$NOWHERE" "pulumi env set organization/core/dev key production")"
    assert_decision NONE "$(decide_in "$NOWHERE" "pulumi env edit organization/core/staging")"
    assert_decision NONE "$(decide_in "$NOWHERE" "pulumi env get organization/core/production key")"
}

@test "pulumi: any --target set on a prod stack is denied" {
    local urn="urn:pulumi:production::core::gcp:cloudrunv2/service:Service::api"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi up -s production --target $urn")"
    assert_decision DENY "$(decide_in "$PU_PROD" "pulumi up --target=$urn")"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi up -s production --target $urn --target-dependents")"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi up -s production --target urn:pulumi:production::core::pulumi:pulumi:Stack::core-production")"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi up -s production --target api")"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi up -s production -t $urn -t $urn -t $urn -t $urn -t $urn -t $urn")"
    assert_decision DENY "$(decide_in "$PU_NONE" "pulumi cancel -s production --target $urn")"
}

@test "none: --admin inside a quoted PR body is not the --admin flag" {
    assert_decision NONE "$(decide "$GH pr create --title t --body \"never use --admin here\"")"
}

@test "none: a pipe and a repo delete inside an echoed string" {
    assert_decision NONE "$(decide "echo \"a | $GH $REPO $DEL x\"")"
}

@test "none: a quoted heredoc body that mentions a repo delete" {
    assert_decision NONE "$(decide "cat <<'EOF'
$GH $REPO $DEL x
EOF")"
}

@test "deny: bash -c with a single-quoted repo delete" {
    assert_decision DENY "$(decide "bash -c '$GH $REPO $DEL x'")"
}

@test "deny: a heredoc fed to bash that runs a repo delete" {
    assert_decision DENY "$(decide "bash <<'EOF'
$GH $REPO $DEL x
EOF")"
}

@test "deny: --admin as a real flag on a later pipeline member" {
    assert_decision DENY "$(decide "echo ok | $GH pr merge 1 --admin")"
}

@test "none: a guarded tool handed to xargs is allowed" {
    assert_decision NONE "$(decide "echo foo/bar | xargs $GH $REPO $DEL")"
}

@test "none: a dynamic command name with no guarded tool in the command fails open" {
    assert_decision NONE "$(decide "\$TOOL $REPO $DEL foo/bar")"
}

@test "none: a dynamic command name in a command that names a guarded tool is allowed" {
    assert_decision NONE "$(decide "T=\$(which $GH); \$T $REPO $DEL foo/bar")"
}

@test "a variable assigned a static command resolves to it" {
    assert_decision NONE "$(decide "S=/tmp/x; \$S/q.sh \"select 1\" | cut -c1-300")"
    assert_decision DENY "$(decide "T=$GH; \$T $REPO $DEL foo/bar")"
}

@test "deny: dynamic code handed to eval is denied (the guard cannot see what it runs)" {
    assert_decision DENY "$(decide "eval \"\$CMD\"")"
}

@test "none: sourcing a script is treated like running one" {
    assert_decision NONE "$(decide "source ./env.sh && echo ok")"
}

@test "none: a test bracket with a variable is an ordinary command" {
    assert_decision NONE "$(decide "[ \"\$X\" = done ] && echo ok")"
}

@test "none: a command that cannot be parsed fails open" {
    assert_decision NONE "$(decide "echo \"unterminated")"
}

@test "none: an unparseable command that names a guarded tool is allowed" {
    assert_decision NONE "$(decide "$GH $REPO $DEL \"unterminated")"
}

@test "none: shell info and syntax-check invocations do not read stdin" {
    assert_decision NONE "$(decide "bash --version | head -1")"
    assert_decision NONE "$(decide "sh --help")"
    assert_decision NONE "$(decide "zsh --version")"
    assert_decision NONE "$(decide "bash -n script.sh")"
    assert_decision NONE "$(decide "bash -xn script.sh")"
    assert_decision NONE "$(decide "bash .github/scripts/x.sh \"\$PWD\"")"
    assert_decision NONE "$(decide "bash --version | head -1; bash .github/scripts/x.sh \"\$PWD\"; bats .github/tests/x.bats 2>&1 | tail -20")"
}

@test "none: shells that read stdin are allowed, dynamic -c code is denied" {
    assert_decision NONE "$(decide "gh api repos/x/y/contents/i.sh | bash")"
    assert_decision NONE "$(decide "bash -s")"
    assert_decision NONE "$(decide "bash")"
    assert_decision DENY "$(decide "bash -c \"\$X\"")"
    assert_decision NONE "$(decide "bash -n +n")"
}

@test "none: curl inside a dynamic shell command is not guarded" {
    assert_decision NONE "$(decide "keyshelf run -- bash -c 'curl -sS -X POST \"\$SUPABASE_URL/x\"'")"
    assert_decision NONE "$(decide "\$T -sS https://example.com")"
    assert_decision NONE "$(decide "curl -X DELETE https://api.github.com/repos/sunsay-ltd/x")"
}

@test "deny: --admin merge explains how to fix the failing check instead of handing the merge to the user" {
    out=$(jq -nc --arg cmd "$GH pr merge 3937 --squash --admin" '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:$cmd}}' | bash "$HOOK")
    r=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
    assert_decision DENY "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z')"
    case "$r" in (*'find the failing required check, fix its cause'*'STATUS: FAILURE admin-merge: <check> fails because <evidence>'*) ;; (*) echo "$r" >&2; return 1 ;; esac
    case "$r" in (*'Ask the user to run it'*) echo "$r" >&2; return 1 ;; esac
}

@test "deny: gh repo delete tells the agent the user must run it" {
    out=$(jq -nc --arg cmd "$GH $REPO $DEL o/r --yes" '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:$cmd}}' | bash "$HOOK")
    case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" in (*'Ask the user to run it themselves'*) ;; (*) return 1 ;; esac
}

@test "deny: creating the done-gate kill switch from Bash" {
    assert_decision DENY "$(decide "touch ~/.claude/state/override/done_gate.off")"
    assert_decision DENY "$(decide "mkdir -p \$HOME/.claude/state/override")"
    assert_decision DENY "$(decide "cat ~/.claude/state/override/done_gate.off")"
}

@test "deny: writing gate state from Bash" {
    assert_decision DENY "$(decide "echo '{}' >> $HOME/.claude/state/sessions/s1/ledger.jsonl")"
    assert_decision DENY "$(decide "printf x > ~/.claude/state/gate.json")"
    assert_decision DENY "$(decide "rm -rf ~/.claude/state/sessions")"
    assert_decision DENY "$(decide_in "$HOME/.claude" "touch state/override/done_gate.off")"
}

@test "none: reading the gate ledger for debugging" {
    assert_decision NONE "$(decide "cat ~/.claude/state/sessions/s1/ledger.jsonl")"
    assert_decision NONE "$(decide "jq . $HOME/.claude/state/sessions/s1/gate.json")"
}

@test "deny: Write and Edit on gate state; other files pass" {
    out=$(jq -nc --arg f "$HOME/.claude/state/override/done_gate.off" '{tool_name:"Write",cwd:"/tmp",tool_input:{file_path:$f,content:""}}' | bash "$HOOK")
    assert_decision DENY "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z')"
    out=$(jq -nc --arg f "$HOME/.claude/state/sessions/s1/ledger.jsonl" '{tool_name:"Edit",cwd:"/tmp",tool_input:{file_path:$f,old_string:"a",new_string:"b"}}' | bash "$HOOK")
    assert_decision DENY "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z')"
    out=$(jq -nc '{tool_name:"Write",cwd:"/tmp",tool_input:{file_path:"/tmp/x.txt",content:""}}' | bash "$HOOK")
    [ -z "$out" ]
}

write_decision() {
    local out
    out=$(jq -nc --arg f "$1" '{tool_name:"Write",cwd:"/tmp",tool_input:{file_path:$f,content:""}}' | bash "$HOOK")
    if [ -z "$out" ]; then echo NONE; else printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z'; fi
}

@test "deny: a Write into an overridden CLAUDE_STATE_DIR and a traversal into the state root" {
    export CLAUDE_STATE_DIR="$BATS_TEST_TMPDIR/gate-state"
    assert_decision DENY "$(write_decision "$BATS_TEST_TMPDIR/gate-state/override/done_gate.off")"
    assert_decision DENY "$(write_decision "$BATS_TEST_TMPDIR/x/../gate-state/./gate.json")"
    unset CLAUDE_STATE_DIR
    assert_decision DENY "$(write_decision "$HOME/.claude/skills/../state/override/done_gate.off")"
}

@test "none: a project's own .claude/state directory is not the gate state" {
    assert_decision NONE "$(write_decision "$BATS_TEST_TMPDIR/repo/.claude/state/cache.json")"
    assert_decision NONE "$(decide "touch $BATS_TEST_TMPDIR/repo/.claude/state/x")"
}

@test "deny: quoted and relative Bash paths into the state root" {
    assert_decision DENY "$(decide "touch \"$HOME/.claude/state/override/done_gate.off\"")"
    assert_decision DENY "$(decide_in "$HOME/.claude/skills" "rm -rf ../state/sessions")"
}

sbq() {
    decide_in "$1" "supabase db query $2"
}

sbq_reason() {
    jq -nc --arg cwd "$1" --arg cmd "supabase db query $2" '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}' | bash "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""'
}

@test "db query: local stays allowed for any SQL, file and stdin" {
    for a in "'insert into t values (1)'" "--local 'drop table t'" "-f x.sql" "--local=true 'delete from t'" "--db-url postgresql://postgres:postgres@127.0.0.1:54322/postgres 'truncate t'" "--db-url=postgres://postgres@localhost/postgres 'drop schema x'"; do
        assert_decision NONE "$(sbq "$SB_PROD" "$a")" || { echo "args: $a" >&2; return 1; }
    done
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db query <<'SQL'
delete from t;
SQL")"
}

@test "db query: read-only transaction forms are allowed against prod, staging and --db-url" {
    for a in \
        "--linked 'begin read only; select 1; commit;'" \
        "--linked 'BEGIN READ ONLY; SELECT * FROM t WHERE a = 1; COMMIT'" \
        "--linked 'begin transaction read only; select 1; rollback;'" \
        "--linked 'begin work read only; select 1; commit work;'" \
        "--linked 'start transaction read only; select 1; commit transaction;'" \
        "--linked 'start transaction isolation level repeatable read, read only; select 1; commit;'" \
        "--linked 'set default_transaction_read_only = on; begin read only; select 1; commit;'" \
        "--linked 'set session characteristics as transaction read only; begin read only; select 1; commit;'" \
        "--linked 'begin read only; with x as (select 1 as a) select case when a = 1 then 2 end from x; commit;'" \
        "--linked 'begin read only; select pg_sleep(1); table t; values (1); show search_path; commit;'" \
        "--linked 'begin read only; explain analyze select 1; explain (analyze, buffers) select 2; commit;'" \
        "--linked 'begin read only; select \$\$insert into t\$\$, \$q\$drop\$q\$, '\\''delete'\\''; commit;'" \
        "--linked 'begin read only; /* note */ select 1; -- trailing
commit; -- done'" \
        "--linked -o json 'begin read only; select comment from feedback; commit;'" \
        "--agent yes --linked 'begin read only; select 1; commit;'" \
        "--db-url postgresql://postgres:pw@db.$PROD_REF.supabase.co:5432/postgres 'begin read only; select 1; commit;'"; do
        assert_decision NONE "$(sbq "$SB_PROD" "$a")" || { echo "args: $a" >&2; return 1; }
        assert_decision NONE "$(sbq "$SB_STG" "$a")" || { echo "args: $a" >&2; return 1; }
    done
    assert_decision NONE "$(decide_in "$SB_PROD" "npx supabase --workdir . db query --linked 'begin read only; select 1; commit;'")"
    assert_decision NONE "$(decide_in "$SB_PROD" "bash -c \"supabase db query --linked 'begin read only; select 1; commit;'\"")"
    assert_decision NONE "$(decide_in "$SB_PROD" "git commit -m 'guard supabase db query --linked'")"
    assert_decision NONE "$(decide_in "$SB_PROD" "bash destroy_worktree.sh supabase-db-query-readonly --delete-branch")"
    assert_decision NONE "$(decide_in "$SB_PROD" "ls /tmp/supabase_query.log")"
    assert_decision NONE "$(decide_in "$SB_PROD" "$GH pr create --title x --body 'needs \`supabase\` at a boundary (\`=\`), then a later query token'")"
    assert_decision NONE "$(decide_in "$SB_PROD" "git commit -m 'scan for supabase db query when a=b'")"
    assert_decision DENY "$(decide_in "$SB_PROD" "git config alias.q '!supabase db query --linked x'")"
}

@test "db query: write and escape SQL against --linked is denied (prod, staging, unlinked)" {
    local s dir
    while IFS= read -r s; do
        [ -n "$s" ] || continue
        for dir in "$SB_PROD" "$SB_STG" "$NOWHERE"; do
            assert_decision DENY "$(sbq "$dir" "--linked '${s//\'/\'\\\'\'}'")" || { echo "sql: $s ($dir)" >&2; return 1; }
        done
    done <"$BATS_TEST_DIRNAME/fixtures/db_query_denied.sql.txt"
}

@test "db query: a multi-line statement after COMMIT is denied" {
    assert_decision DENY "$(sbq "$SB_PROD" "--linked 'begin read only; select 1; -- comment
insert into t values (1); commit;'")"
    assert_decision DENY "$(sbq "$SB_PROD" "--linked 'begin read only; select 1; commit;
delete from t;'")"
}

@test "db query: backslashes, psql meta-commands and non-ASCII outside literals are denied" {
    for a in \
        "--linked 'begin read only; select 1; commit; \\! rm -rf /'" \
        "--linked 'begin read only; select E''\\'''' ; commit;'" \
        "--linked 'begin read only; select ''\\'' ; delete from t; commit;'" \
        "--linked \$'begin read only; select 1; commit;\\ninsert into t values (1);'" \
        "--linked 'begin read only; select 1; commit; insert into t values (1);'" \
        "--linked 'begin read only; select 1$(printf '\302\240'); commit;'" \
        "--linked 'begin read only; select 1;$(printf '\342\200\250')commit;'" \
        "--linked 'begin read only; select 1; commit;$(printf '\001')'" \
        "--linked 'begin read only; selеct 1; commit;'"; do
        assert_decision DENY "$(sbq "$SB_PROD" "$a")" || { echo "args: $a" >&2; return 1; }
    done
}

@test "db query: SQL the guard cannot read statically is denied against a remote target" {
    for a in \
        "--linked -f q.sql" \
        "--linked --file q.sql" \
        "--linked --file=q.sql" \
        "--linked -fq.sql" \
        "--linked" \
        "--linked \"\$SQL\"" \
        "--linked \"\$(cat q.sql)\"" \
        "--linked \"\$(echo YmVnaW4= | base64 -d)\"" \
        "--linked 'begin read only; select 1; commit;' 'delete from t'" \
        "--linked begin*" \
        "--linked 'begin read only; select 1; commit;'{,x}" \
        "--linked --unknown 'begin read only; select 1; commit;'" \
        "--linked -x 'begin read only; select 1; commit;'"; do
        assert_decision DENY "$(sbq "$SB_PROD" "$a")" || { echo "args: $a" >&2; return 1; }
    done
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase db query --linked <<'SQL'
begin read only; select 1; commit;
SQL")"
    assert_decision DENY "$(decide_in "$SB_PROD" "echo 'begin read only; select 1; commit;' | supabase db query --linked")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase db query --linked <<< 'begin read only; select 1; commit;'")"
}

@test "db query: remote signals beat --local, and env-based targets are remote" {
    assert_decision DENY "$(sbq "$SB_PROD" "--local --linked 'delete from t'")"
    assert_decision DENY "$(sbq "$SB_PROD" "--linked --local 'delete from t'")"
    assert_decision DENY "$(sbq "$SB_PROD" "--local=false 'delete from t'")"
    assert_decision DENY "$(sbq "$SB_PROD" "--db-url postgresql://postgres:pw@db.$STG_REF.supabase.co:5432/postgres 'delete from t'")"
    assert_decision DENY "$(sbq "$SB_PROD" "--db-url 'postgresql://postgres@127.0.0.1:54322/postgres?host=db.$PROD_REF.supabase.co' 'delete from t'")"
    assert_decision DENY "$(sbq "$SB_PROD" "--db-url 'host=127.0.0.1 port=5432' 'delete from t'")"
    assert_decision DENY "$(sbq "$SB_PROD" "--db-url \"\$DB\" 'delete from t'")"
    assert_decision DENY "$(sbq "$SB_PROD" "--db-url postgresql://u@evil@127.0.0.1/postgres 'delete from t'")"
    assert_decision DENY "$(decide_in "$SB_PROD" "SUPABASE_DB_URL=postgresql://x@db.$PROD_REF.supabase.co/postgres supabase db query 'delete from t'")"
    assert_decision DENY "$(decide_in "$SB_PROD" "SUPABASE_LINKED=true supabase db query 'delete from t'")"
    assert_decision DENY "$(decide_in "$SB_PROD" "env SUPABASE_LINKED=1 supabase db query 'delete from t'")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase --agent yes db query --linked 'delete from t'")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase --linked db query 'delete from t'")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase --agent no db push")"
}

@test "db query: wrappers and nested shells are covered" {
    for c in \
        "npx supabase db query --linked 'delete from t'" \
        "pnpm exec supabase db query --linked 'delete from t'" \
        "bunx supabase db query --linked 'delete from t'" \
        "bash -c \"supabase db query --linked 'delete from t'\"" \
        "eval \"supabase db query --linked 'delete from t'\"" \
        "cd /tmp && supabase db query --linked 'delete from t'" \
        "Supabase db query --linked 'delete from t'" \
        "SUPABASE db query --linked 'delete from t'" \
        "/opt/homebrew/bin/supabase db query --linked 'delete from t'" \
        "npx SupaBase db query --linked 'delete from t'" \
        "pnpx supabase db query --linked 'delete from t'" \
        "npm exec supabase -- db query --linked 'delete from t'" \
        "npx -p supabase supabase db query --linked 'delete from t'" \
        "xargs supabase db query --linked </dev/null" \
        "echo x | xargs -I{} supabase db query --linked {}" \
        "find . -exec supabase db query --linked 'delete from t' \\;" \
        "supabase db query \"\$F\" 'delete from t'" \
        "supabase db \"\$SUB\" --linked 'delete from t'" \
        "supabase \$(echo db) query --linked 'delete from t'" \
        "env -S \"supabase db query --linked 'delete from t'\"" \
        "env --split-string=\"supabase db query --linked 'delete from t'\"" \
        "env -S supabase db query --linked 'delete from t'" \
        "script -q /dev/null \"supabase db query --linked 'delete from t'\"" \
        "flock /tmp/l -c \"supabase db query --linked 'delete from t'\"" \
        "git -c \"alias.q=!supabase db query --linked 'delete from t'\" q" \
        "git -c core.pager=\"supabase db query --linked 'delete from t'\" log" \
        "git -c \"core.sshCommand supabase db query\" fetch" \
        "\"\$RUN\" db query --linked 'delete from t'" \
        "\$(echo supabase) db query --linked 'delete from t'"; do
        assert_decision DENY "$(decide_in "$SB_PROD" "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "guard: command names are matched case-insensitively (macOS resolves Gh and Supabase)" {
    assert_decision DENY "$(decide "Gh pr merge 1 --admin")"
    assert_decision DENY "$(decide_in "$SB_PROD" "SUPABASE db push")"
}

@test "db query: an unparseable command that mentions supabase query is denied" {
    local out
    out=$(jq -nc --arg cmd "supabase db query --linked 'delete from t' \$((" '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:$cmd}}' | bash "$HOOK")
    assert_decision DENY "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z')"
    out=$(jq -nc --arg cmd "echo hi \$((" '{tool_name:"Bash",cwd:"/tmp",tool_input:{command:$cmd}}' | bash "$HOOK")
    [ -z "$out" ]
}

@test "db query: the deny message tells the agent the exact allowed form" {
    local r
    r=$(sbq_reason "$SB_PROD" "--linked 'delete from t'")
    [[ $r == *"begin read only; select ...; commit;"* ]]
    [[ $r == *"Rejected because:"* ]]
    [[ $r == *"writes must be run manually by the user"* ]]
    r=$(sbq_reason "$SB_PROD" "--linked -f q.sql")
    [[ $r == *"-f/--file"* ]]
    r=$(sbq_reason "$SB_PROD" "--linked 'set default_transaction_read_only = on; select 1; commit;'")
    [[ $r == *"must be BEGIN READ ONLY"* ]]
}

@test "db query: the guard fails closed when the SQL validator cannot run" {
    local fake="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake"
    printf '#!/bin/sh\nexit 127\n' >"$fake/python3"
    chmod +x "$fake/python3"
    assert_decision DENY "$(PATH="$fake:$PATH" sbq "$SB_PROD" "--linked 'begin read only; select 1; commit;'")"
}

@test "remote db: local psql, pg_dump and pgcli stay allowed" {
    local c
    for c in \
        "psql -h 127.0.0.1 -p 54322 -U postgres -c 'select 1'" \
        "psql -h localhost -d postgres -c 'select 1'" \
        "psql -h LocalHost -c 'select 1'" \
        "psql --host=127.0.0.1 postgres" \
        "psql --host ::1 postgres" \
        "psql -h /tmp postgres" \
        "psql -h /var/run/postgresql,localhost postgres" \
        "psql -Atc 'select 1' -h 127.0.0.1" \
        "psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -f migration.sql" \
        "psql postgres" \
        "psql" \
        "psql postgresql://postgres:postgres@127.0.0.1:54322/postgres -c 'select 1'" \
        "psql 'postgres://postgres@localhost/postgres?sslmode=disable'" \
        "psql 'postgresql://postgres@[::1]:54322/postgres'" \
        "psql 'postgresql:///postgres?host=/var/run/postgresql'" \
        "psql 'postgresql://%2Fvar%2Frun%2Fpostgresql/postgres'" \
        "psql 'host=localhost port=54322 dbname=postgres user=postgres'" \
        "psql -d 'host=127.0.0.1 dbname=postgres'" \
        "PGHOST=127.0.0.1 psql -c 'select 1'" \
        "PGHOST=/tmp PGHOSTADDR=127.0.0.1 psql" \
        "psql -h 127.0.0.1 -c '\\dt'" \
        "psql -h 127.0.0.1 -c '\\c otherdb'" \
        "psql -h 127.0.0.1 -c '\\connect otherdb postgres localhost 54322'" \
        "psql -h 127.0.0.1 <<'SQL'
select 1;
SQL" \
        "pg_dump -h 127.0.0.1 -p 54322 -U postgres -f out.sql postgres" \
        "pg_dump -cf out.sql postgresql://postgres@localhost:54322/postgres" \
        "pg_dumpall -h localhost -f all.sql" \
        "pg_restore -h 127.0.0.1 -d postgres dump.bin" \
        "pgcli postgres://postgres@localhost:54322/postgres" \
        "docker exec supabase_db psql -U postgres -c 'select 1'" \
        "bash -c 'psql -h 127.0.0.1 -c \"select 1\"'" \
        "grep -rn psql docs/" \
        "grep -rn psql \"\$DIR\"" \
        "which psql pg_dump" \
        "brew install libpq" \
        "echo 'use psql against localhost'"; do
        assert_decision NONE "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "remote db: psql and friends against a remote host are denied" {
    local c R="db.$PROD_REF.supabase.co"
    for c in \
        "psql -h $R -U postgres -c 'select 1'" \
        "psql --host $R postgres" \
        "psql --host=$R postgres" \
        "psql -h$R postgres" \
        "psql -Xh $R postgres" \
        "psql --ho=$R postgres" \
        "psql --hos $R postgres" \
        "PSQL -h $R" \
        "Psql -h $R" \
        "/opt/homebrew/opt/libpq/bin/psql -h $R" \
        "psql -h DB.Example.COM" \
        "psql -h localhost,$R postgres" \
        "psql -h 127.0.0.2 postgres" \
        "psql postgresql://postgres:pw@$R:5432/postgres" \
        "psql POSTGRESQL://postgres:pw@$R:5432/postgres" \
        "psql PostgreS://postgres@$R/postgres" \
        "psql 'postgresql://postgres@127.0.0.1@$R/postgres'" \
        "psql 'postgresql://localhost,$R/postgres'" \
        "psql 'postgresql://localhost/postgres?host=$R'" \
        "psql 'postgresql://localhost/postgres?hostaddr=10.0.0.1'" \
        "psql 'postgresql://%64b.example.com/postgres'" \
        "psql 'postgresql://localhost/postgres?service=prod'" \
        "psql 'host=$R dbname=postgres'" \
        "psql \"dbname=postgres host='$R'\"" \
        "psql 'HOST=$R'" \
        "psql 'hostaddr=1.2.3.4 dbname=postgres'" \
        "psql 'service=prod'" \
        "psql 'dbname=postgresql://$R/postgres'" \
        "psql -d 'host=$R'" \
        "psql --dbname=host=$R" \
        "psql --dbname 'postgresql://$R/postgres'" \
        "PGHOST=$R psql -c 'select 1'" \
        "PGHOSTADDR=1.2.3.4 psql" \
        "PGSERVICE=prod psql" \
        "PGDATABASE=postgresql://$R/postgres psql" \
        "env PGHOST=$R psql" \
        "DATABASE_URL=postgresql://$R/postgres psql \"\$DATABASE_URL\"" \
        "psql \"\$DATABASE_URL\" -c 'select 1'" \
        "psql \"\$DB_URL\"" \
        "psql -h \"\$PGHOST_REMOTE\" postgres" \
        "PGHOST=\$H psql" \
        "psql \$(cat url.txt)" \
        "psql -h 127.0.0.1 -c \"\$SQL\"" \
        "pg_dump -h $R -f out.sql postgres" \
        "pg_dump postgresql://postgres@$R/postgres" \
        "PG_DUMP --host=$R" \
        "pg_dumpall -d postgresql://postgres@$R/postgres" \
        "pg_dumpall -l 'host=$R'" \
        "pg_restore -d postgresql://postgres@$R/postgres dump.bin" \
        "pg_restore -h $R -d postgres dump.bin" \
        "pgcli postgres://postgres@$R/postgres" \
        "pgcli -h $R" \
        "pgcli -D prod" \
        "pgcli --dsn prod" \
        "pgcli --ssh-tunnel u@bastion postgres://localhost/postgres"; do
        assert_decision DENY "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "remote db: psql meta-commands, wrappers and embedded psql cannot leave localhost" {
    local c R="db.$PROD_REF.supabase.co"
    for c in \
        "psql -h 127.0.0.1 -c '\\c postgresql://postgres@$R/postgres'" \
        "psql -h 127.0.0.1 -c '\\connect host=$R'" \
        "psql -h 127.0.0.1 -c '\\c postgres postgres $R'" \
        "psql -h 127.0.0.1 -c '\\c :target'" \
        "psql -h 127.0.0.1 -c '\\! psql -h $R'" \
        "psql -h 127.0.0.1 -c '\\setenv PGHOST $R'" \
        "psql -h 127.0.0.1 -c 'select 1 \\g | sh'" \
        "psql -h 127.0.0.1 -c \"\\copy t from program 'curl x'\"" \
        "psql -h 127.0.0.1 -c '\\set x \`id\`'" \
        "psql -h 127.0.0.1 <<'SQL'
\\connect host=$R
delete from t;
SQL" \
        "echo '\\c host=$R' | psql -h 127.0.0.1" \
        "psql -h 127.0.0.1 <<< '\\c host=$R'" \
        "bash -c 'psql -h $R'" \
        "sh -c \"psql -h $R -c 'delete from t'\"" \
        "eval \"psql -h $R\"" \
        "docker exec c psql -h $R" \
        "docker run --rm postgres:17 psql postgresql://postgres@$R/postgres" \
        "kubectl exec -it pod -- psql -h $R" \
        "xargs psql -h $R </dev/null" \
        "npx psql -h $R" \
        "ssh bastion psql -h localhost" \
        "ssh bastion 'psql -h localhost'" \
        "git -c \"alias.p=!psql -h $R\" p" \
        "git config alias.p '!psql -h $R'" \
        "python3 -c \"import os; os.system('psql -h $R')\"" \
        "node -e \"require('child_process').execSync('pg_dump postgresql://u@$R/postgres')\"" \
        "\$P -h $R postgres" \
        "psql -h $R \$(("; do
        assert_decision DENY "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "remote db: the Supabase Management API database endpoints are denied" {
    local c U="https://api.supabase.com/v1/projects/$STG_REF/database/query"
    for c in \
        "curl -X POST $U -H 'Authorization: Bearer x' -d '{\"query\":\"select 1\"}'" \
        "CURL -X POST $U" \
        "Curl $U" \
        "/usr/bin/curl --url $U" \
        "curl \"https://api.supabase.com/v1/projects/\$REF/database/query\"" \
        "curl \"\$API/v1/projects/x/database/query\"" \
        "curl \"https://api.supabase.com/\$P\"" \
        "curl https://API.SUPABASE.COM/v1/projects/x/database/query" \
        "curl https://api.supabase.com/v1/projects/x/%64atabase/query" \
        "curl https://api.supabase.com/v1/projects/x/data%2562ase/query" \
        "curl 'https://api.supabase.com/v1/projects/x/{database}/query'" \
        "curl 'https://api.supabase.com/v1/projects/x/[d-d]atabase/query'" \
        "curl https://api.supabase.com//v1//projects/x/database/migrations" \
        "curl https://api.supabase.com/platform/pg-meta/x/query" \
        "curl https://api.supabase.io/v1/projects/x/database/query" \
        "curl --connect-to example.com:443:api.supabase.com:443 https://example.com/v1/projects/x/database/query" \
        "wget --post-data='{}' $U" \
        "http POST api.supabase.com/v1/projects/x/database/query query='select 1'" \
        "xh POST $U query='select 1'" \
        "gh api $U" \
        "bash -c 'curl -X POST $U'" \
        "echo x | xargs curl -X POST $U" \
        "keyshelf run -- curl -X POST $U" \
        "python3 -c \"import urllib.request as r; r.urlopen('$U')\""; do
        assert_decision DENY "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
    for c in \
        "curl https://api.supabase.com/v1/projects" \
        "curl -sS https://api.supabase.com/v1/projects/$STG_REF/api-keys" \
        "curl https://example.com/database" \
        "gh api repos/sunsay-ltd/core/pulls" \
        "git commit -m 'guard curl to /v1/projects/x/database/query'"; do
        assert_decision NONE "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "remote db: eval and sh -c of dynamic code are denied, static code is parsed" {
    local c
    for c in \
        "eval \"\$CMD\"" \
        "eval \$CMD" \
        "eval \"supabase \$X\"" \
        "eval \"psql \$ARGS\"" \
        "eval \"\$(echo cHNxbA== | base64 -d) -h db.x\"" \
        "X=\$(cat cmd.txt); eval \"\$X\"" \
        "bash -c \"\$X\"" \
        "sh -c \"psql -h \$H\"" \
        "zsh -c \"\$CMD\"" \
        "bash -lc \"supabase db query --linked \$Q\"" \
        "bash <<< \"\$X\"" \
        "bash <<EOF
psql -h \$H
EOF"; do
        assert_decision DENY "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
    for c in \
        "eval 'echo hi'" \
        "bash -c 'echo hi'" \
        "sh -c 'ls -la'"; do
        assert_decision NONE "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "remote db: deny messages point at the allowed supabase db query form" {
    local r
    r=$(decide_reason "psql -h db.example.com")
    [[ $r == *"supabase db query --linked 'begin read only; select ...; commit;'"* ]]
    [[ $r == *"127.0.0.1, localhost, ::1 or a unix socket"* ]]
    r=$(decide_reason "curl https://api.supabase.com/v1/projects/x/database/query")
    [[ $r == *"Management API"* && $r == *"begin read only; select ...; commit;"* ]]
    r=$(decide_reason "eval \"\$CMD\"")
    [[ $r == *"Write the command out literally"* && $r == *"begin read only; select ...; commit;"* ]]
}

@test "remote db: the guard fails closed when the remote-db checker cannot run" {
    local fake="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$fake"
    printf '#!/bin/sh\nexit 127\n' >"$fake/python3"
    chmod +x "$fake/python3"
    assert_decision DENY "$(PATH="$fake:$PATH" decide "psql -h 127.0.0.1 -c 'select 1'")"
}

@test "remote db: any wrapper and env -S around a client or a Management API call are checked" {
    local c R="db.$PROD_REF.supabase.co" U="https://api.supabase.com/v1/projects/$STG_REF/database/query"
    for c in \
        "env -S 'psql -h $R'" \
        "env -S 'curl -X POST $U'" \
        "env --split-string='pg_dump postgresql://u@$R/postgres'" \
        "doas psql -h $R" \
        "DOAS PSQL -h $R" \
        "doas curl -X POST $U" \
        "nice -n 5 psql -h $R" \
        "time pgcli -h $R" \
        "stdbuf -oL pg_restore -h $R -d postgres dump.bin"; do
        assert_decision DENY "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
    for c in \
        "env -S 'psql -h 127.0.0.1 -c \"select 1\"'" \
        "env -S 'echo hi'" \
        "doas psql -h localhost" \
        "nice -n 5 pg_dump -h 127.0.0.1 -f out.sql postgres" \
        "man psql" \
        "brew install curl"; do
        assert_decision NONE "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "remote db: libpq variables set earlier in the command, curl URL globs and no-connect flags" {
    local c R="db.$PROD_REF.supabase.co"
    for c in \
        "export PGHOST=$R; psql" \
        "PGHOST=$R; export PGHOST; psql -c 'select 1'" \
        "declare -x PGHOSTADDR=1.2.3.4 && pg_dump postgres" \
        "export PGSERVICE=prod; psql" \
        "export PGDATABASE=postgresql://$R/postgres; psql" \
        "export PGHOST=\"\$H\"; psql" \
        "read PGHOST <h.txt; psql" \
        "curl 'https://api.supabase.com/v1/projects/x/{data,foo}base/query'" \
        "CURL 'https://api.supabase.com/v1/projects/x/[c-e]atabase'" \
        "curl https://api.supabase.com:443/v1/projects/x/database/query" \
        "curl https://api.supabase.com./v1/projects/x/database/query"; do
        assert_decision DENY "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
    for c in \
        "export PGHOST=127.0.0.1; psql" \
        "export PGHOST='/tmp' PGDATABASE=postgres; psql" \
        "echo \$PGHOST; psql -h localhost" \
        "psql --version --host=$R" \
        "pg_dump -V" \
        "pgcli --help" \
        "curl https://api.supabase.com.example.org/v1/x"; do
        assert_decision NONE "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "remote db: dynamic -h behind an unknown wrapper, assembled /v1/projects URLs, query strings and PGHOST mentions" {
    local c
    for c in \
        "ionice -c 3 psql -h \"\$(printf db.example.com)\"" \
        "doas psql --host=\"\$H\"" \
        "curl \"https://\$(printf api.supabase.com)/v1/projects/x/\$(printf database/query)\"" \
        "Wget \"https://\$HOST/v1/projects/x/\$P\""; do
        assert_decision DENY "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
    for c in \
        "ionice -c 3 psql -h 127.0.0.1" \
        "grep -rn psql \"\$DIR\"" \
        "curl 'https://api.supabase.com/v1/projects?search=database'" \
        "psql -h 127.0.0.1; echo PGHOST"; do
        assert_decision NONE "$(decide "$c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

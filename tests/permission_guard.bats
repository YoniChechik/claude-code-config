#!/usr/bin/env bats

setup() {
    HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/pre_tool_use__permission_guard.sh"

    GH="g""h"
    REPO="rep""o"
    DEL="del""ete"
    GC="gclo""ud"
    INST="comp""ute"
    INSTANCES="instanc""es"

    unset SUPABASE_PROJECT_ID SUPABASE_WORKDIR PULUMI_STACK PULUMI_BACKEND_URL
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

make_pulumi_project() { # <dir> <name> <workspace-json> [backend-url]
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

decide_in() { # <cwd> <command> -> NONE | ASK | DENY
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

assert_decision() { # <expected> <actual>
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

@test "deny: gh repo delete, direct" {
    assert_decision DENY "$(decide "$GH $REPO $DEL foo/bar")"
}

@test "ask: gh repo archive requires confirmation" {
    assert_decision ASK "$(decide "$GH repo archive foo/bar")"
}

@test "ask: gcloud compute instances delete, direct" {
    assert_decision ASK "$(decide "$GC $INST instances $DEL x")"
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

@test "ask: backtick command substitution assigned to a variable" {
    assert_decision ASK "$(decide "X=\`$GC $INST instances $DEL x\`")"
}

@test "deny: \`command\` builtin prefix" {
    assert_decision DENY "$(decide "command $GH $REPO $DEL foo/bar")"
}

@test "ask: \`command\` builtin prefix on gcloud" {
    assert_decision ASK "$(decide "command $GC $INST instances $DEL x")"
}

@test "deny: backslash-escaped leading command word" {
    assert_decision DENY "$(decide "\\$GH $REPO $DEL foo/bar")"
}

@test "ask: bare VAR=value env-prefix before gcloud" {
    assert_decision ASK "$(decide "FOO=bar $GC $INST instances $DEL x")"
}

@test "deny: \`env\` builtin prefix" {
    assert_decision DENY "$(decide "env $GH $REPO $DEL foo/bar")"
}

@test "deny: nested command substitution inside a double-quoted string" {
    assert_decision DENY "$(decide "echo \"result: \$($GH $REPO $DEL foo/bar)\"")"
}

@test "ask: pulumi -C flag-prefixed destructive subcommand still recognized" {
    assert_decision ASK "$(decide "pulumi -C infra up")"
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

@test "ask: a grammar-wrapped ask-level command is still recognized" {
    assert_decision ASK "$(decide "{ $GC $INST $INSTANCES $DEL x; }")"
}

@test "deny: gh ask-rule first, raw-HTTP deny-rule second" {
    local url="https://api.git""hub.com/repos/sun""say-ltd/x"
    assert_decision DENY "$(decide "$GH repo archive foo/bar && curl -X DELETE $url")"
}

@test "deny: gcloud ask-rule first, gcloud-run prod deny-rule second" {
    local cmd="$GC $INST $INSTANCES $DEL x && $GC run deploy --project=production-490411"
    assert_decision DENY "$(decide "$cmd")"
}

@test "deny: bq ask-rule first, pulumi prod deny-rule second" {
    assert_decision DENY "$(decide "bq rm mydataset.mytable && pulumi up --stack production")"
}

@test "deny: gh ask-rule first, gh repo delete deny-rule later in the same command" {
    assert_decision DENY "$(decide "$GH repo archive foo/bar && $GH $REPO $DEL foo/bar")"
}

@test "deny: gh ask-rule first, supabase prod deny-rule second" {
    assert_decision DENY "$(decide "$GH repo archive foo/bar && supabase functions deploy x --project-ref $PROD_REF")"
}

@test "ask: an ask-only compound command still asks (deny is never invented)" {
    assert_decision ASK "$(decide "$GH repo archive foo/bar && $GH repo rename baz")"
}

@test "ask: a broken shared library fails closed instead of silently allowing" {
    local dir="$BATS_TEST_TMPDIR/brokenlib"
    mkdir -p "$dir"
    cp "$HOOK" "$dir/"
    local out
    out=$(jq -nc --arg cmd "$GH $REPO $DEL foo/bar" '{tool_name:"Bash",tool_input:{command:$cmd}}' \
        | bash "$dir/$(basename "$HOOK")")
    [ -n "$out" ]
    assert_decision ASK "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z')"
}

@test "supabase: --db-url beats --local, so db reset --local --db-url <prod> is denied" {
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase db reset --local --db-url postgresql://postgres:pw@db.$PROD_REF.supabase.co:5432/postgres")"
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase db reset --db-url=postgresql://postgres.$PROD_REF2:pw@aws-0-eu-central-1.pooler.supabase.com:6543/postgres --local")"
}

@test "supabase: npx db push in a prod-linked dir is denied, staging asks" {
    assert_decision DENY "$(decide_in "$SB_PROD" "npx supabase db push")"
    assert_decision DENY "$(decide_in "$SB_PROD2" "npx supabase db push")"
    assert_decision ASK "$(decide_in "$SB_STG" "npx supabase db push")"
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

@test "supabase: always-local commands are allowed (stop no longer asks, link is allowed)" {
    for c in "start" "stop" "status" "init" "functions serve" "migration new add_table" "link --project-ref $PROD_REF"; do
        assert_decision NONE "$(decide_in "$SB_PROD" "supabase $c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "supabase: global flags before the subcommand (--experimental db reset --linked)" {
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase --experimental db reset --linked")"
    assert_decision ASK "$(decide_in "$SB_STG" "supabase --experimental db reset --linked")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase --experimental db reset --local")"
}

@test "supabase: default-local commands targeting remote via --linked follow the ref" {
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase migration up --linked")"
    assert_decision ASK "$(decide_in "$SB_STG" "supabase db diff --linked")"
    assert_decision ASK "$(decide_in "$NOWHERE" "supabase db reset --linked")"
}

@test "supabase: target precedence --db-url > --local > --linked" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --linked --db-url postgresql://postgres:postgres@127.0.0.1:54322/postgres")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --linked --local")"
}

@test "supabase: default-linked commands with no flag are remote" {
    for c in "migration repair 2024 --status applied" "migration list" "migration fetch" "db dump" "db pull" "storage rm ss:///b/x" "storage cp a ss:///b/a" "storage mv ss:///b/a ss:///b/c" "inspect db bloat"; do
        assert_decision DENY "$(decide_in "$SB_PROD" "supabase $c")" || { echo "cmd: $c" >&2; return 1; }
    done
    assert_decision ASK "$(decide_in "$SB_STG" "supabase migration repair 2024 --status applied")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase storage ls --local")"
}

@test "supabase: unresolvable ref on a remote command asks" {
    assert_decision ASK "$(decide_in "$NOWHERE" "supabase db push")"
    assert_decision ASK "$(decide_in "$NOWHERE" "supabase functions deploy fn")"
}

@test "supabase: cd X && is honored for the ref lookup" {
    assert_decision DENY "$(decide_in "$NOWHERE" "cd $SB_PROD && supabase db push")"
    assert_decision ASK "$(decide_in "$SB_PROD" "cd $SB_STG && supabase db push")"
}

@test "supabase: --workdir, --workdir= and SUPABASE_WORKDIR are honored" {
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase db push --workdir $SB_PROD")"
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase --workdir=$SB_PROD db push")"
    assert_decision DENY "$(decide_in "$NOWHERE" "SUPABASE_WORKDIR=$SB_PROD supabase db push")"
    assert_decision ASK "$(decide_in "$SB_PROD" "supabase db push --workdir $SB_STG")"
}

@test "supabase: SUPABASE_PROJECT_ID beats the linked project-ref file" {
    assert_decision DENY "$(decide_in "$SB_STG" "SUPABASE_PROJECT_ID=$PROD_REF supabase db push")"
    assert_decision ASK "$(decide_in "$SB_PROD" "SUPABASE_PROJECT_ID=$STG_REF2 supabase db push")"
    assert_decision DENY "$(SUPABASE_PROJECT_ID=$PROD_REF decide_in "$NOWHERE" "supabase db push")"
}

@test "supabase: API-only commands follow --project-ref, then the linked ref" {
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase functions deploy fn --project-ref $PROD_REF")"
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase functions delete fn --project-ref=$PROD_REF2")"
    assert_decision ASK "$(decide_in "$SB_PROD" "supabase functions deploy fn --project-ref $STG_REF")"
    assert_decision ASK "$(decide_in "$NOWHERE" "supabase secrets set --project-ref \$REF A=b")"
    for c in "secrets set A=b" "secrets unset A" "config push" "branches create x" "branches delete x" "postgres-config update --config x=y" "backups restore --timestamp 1" "domains create" "sso add" "network-restrictions update" "network-bans remove" "ssl-enforcement update --enable-db-ssl-enforcement"; do
        assert_decision DENY "$(decide_in "$SB_PROD" "supabase $c")" || { echo "cmd: $c" >&2; return 1; }
        assert_decision ASK "$(decide_in "$SB_STG" "supabase $c")" || { echo "cmd: $c (staging)" >&2; return 1; }
    done
}

@test "supabase: projects delete uses its positional ref" {
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase projects delete $PROD_REF")"
    assert_decision ASK "$(decide_in "$SB_PROD" "supabase projects delete $STG_REF")"
}

@test "supabase: --dry-run only allows subcommands that implement it" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --dry-run")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db dump --dry-run")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase functions deploy fn --dry-run")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase migration repair 1 --status applied --dry-run")"
}

@test "supabase: gen types is local only with --local, remote with --project-id/--linked, else asks" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase gen types typescript --local")"
    assert_decision DENY "$(decide_in "$NOWHERE" "supabase gen types typescript --project-id $PROD_REF")"
    assert_decision ASK "$(decide_in "$NOWHERE" "supabase gen types typescript --project-id $STG_REF")"
    assert_decision DENY "$(decide_in "$SB_PROD" "supabase gen types typescript --linked")"
    assert_decision ASK "$(decide_in "$SB_STG" "supabase gen types typescript")"
}

@test "supabase: --db-url loopback allows, remote asks, unresolved variable asks" {
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --db-url postgresql://postgres:postgres@127.0.0.1:54322/postgres")"
    assert_decision NONE "$(decide_in "$SB_PROD" "supabase db push --db-url 'postgresql://postgres:postgres@localhost:54322/postgres'")"
    assert_decision ASK "$(decide_in "$SB_PROD" "supabase db push --db-url postgresql://u:p@db.$STG_REF.supabase.co:5432/postgres")"
    assert_decision ASK "$(decide_in "$SB_PROD" "supabase db push --db-url \"\$DATABASE_URL\"")"
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

@test "pulumi: non-prod stacks ask, unresolvable stacks ask" {
    assert_decision ASK "$(decide_in "$PU_STG" "pulumi up")"
    assert_decision ASK "$(decide_in "$PU_NONE" "pulumi up")"
    assert_decision ASK "$(decide_in "$PU_NONE" "pulumi up -s organization/x/staging")"
}

@test "pulumi: stack names are matched on the exact last segment, never by substring" {
    for s in domain-staging remain organization/x/production-copy prod-eu organization/main/dev; do
        assert_decision ASK "$(decide_in "$PU_NONE" "pulumi up -s $s")" || { echo "stack: $s" >&2; return 1; }
    done
}

@test "pulumi: PULUMI_STACK prefix and environment select the stack" {
    assert_decision DENY "$(decide_in "$PU_STG" "PULUMI_STACK=organization/core/production pulumi up")"
    assert_decision ASK "$(decide_in "$PU_PROD" "PULUMI_STACK=organization/core/dev pulumi up")"
    assert_decision DENY "$(PULUMI_STACK=prod decide_in "$PU_NONE" "pulumi up")"
}

@test "pulumi: -C, --cwd= and cd X && locate the workspace" {
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi -C $PU_PROD up")"
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi up --cwd=$PU_PROD")"
    assert_decision DENY "$(decide_in "$NOWHERE" "cd $PU_PROD && pulumi up")"
    assert_decision ASK "$(decide_in "$PU_PROD" "cd $PU_STG && pulumi up")"
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
    assert_decision ASK "$(decide_in "$nodir" "pulumi up")"
    assert_decision DENY "$(decide_in "$PU_STG" "PULUMI_BACKEND_URL=gs://production-pulumi-state pulumi up")"
}

@test "pulumi: deployment runs and settings changes follow the resolved stack" {
    for c in "deployment run up" "deployment run destroy" "deployment settings configure" "deployment settings destroy" "deployment settings push"; do
        assert_decision DENY "$(decide_in "$PU_PROD" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
        assert_decision ASK "$(decide_in "$PU_STG" "pulumi $c")" || { echo "cmd: $c (staging)" >&2; return 1; }
    done
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi deployment run up -s organization/core/production")"
    assert_decision NONE "$(decide_in "$PU_PROD" "pulumi deployment settings pull")"
}

@test "pulumi: org-wide policy changes ask, local project commands have no opinion" {
    for c in "policy publish org" "policy enable org/pack latest" "policy disable org/pack" "policy rm org/pack 1"; do
        assert_decision ASK "$(decide_in "$PU_NONE" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
    done
    for c in "new gcp-typescript --yes" "plugin install resource gcp" "policy ls" "policy new aws-typescript" "stack init organization/core/dev" "login gs://bucket"; do
        assert_decision NONE "$(decide_in "$PU_PROD" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
    done
}

@test "pulumi: the mutating set follows the resolved stack" {
    for c in "destroy" "refresh" "import aws:s3/bucket:Bucket b id" "cancel" "watch" "state delete urn:x" "state rename urn:x y" "state move --dest organization/core/dev urn:x" "state unprotect urn:x" "state protect urn:x" "state repair" "state taint urn:x" "state untaint urn:x" "state upgrade" "stack rm" "stack rename organization/core/next" "stack import --file x.json" "stack tag set k v" "stack tag rm k" "stack change-secrets-provider passphrase" "config set k v" "config set-all --plaintext k=v" "config rm k" "config rm-all k" "config cp --dest organization/core/dev" "config refresh"; do
        assert_decision DENY "$(decide_in "$PU_PROD" "pulumi $c")" || { echo "cmd: $c" >&2; return 1; }
        assert_decision ASK "$(decide_in "$PU_STG" "pulumi $c")" || { echo "cmd: $c (staging)" >&2; return 1; }
    done
}

@test "pulumi: stack-name positionals and move/copy destinations are checked" {
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi stack rm organization/core/production --yes")"
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi stack select --create organization/core/prod")"
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi stack rename organization/core/production")"
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi state move --source organization/core/dev --dest organization/core/production urn:x")"
    assert_decision DENY "$(decide_in "$PU_STG" "pulumi config cp -d organization/core/production")"
    assert_decision ASK "$(decide_in "$PU_STG" "pulumi stack select -c organization/core/dev2")"
}

@test "pulumi: ESC environment mutations follow the environment name" {
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi env set organization/core/production key value")"
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi env rm organization/core/prod")"
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi env clone organization/core/dev organization/core/production")"
    assert_decision DENY "$(decide_in "$NOWHERE" "pulumi env version tag organization/core/production@3 stable")"
    assert_decision ASK "$(decide_in "$NOWHERE" "pulumi env set organization/core/dev key production")"
    assert_decision ASK "$(decide_in "$NOWHERE" "pulumi env edit organization/core/staging")"
    assert_decision NONE "$(decide_in "$NOWHERE" "pulumi env get organization/core/production key")"
}

@test "pulumi: a tight --target set on a prod stack asks instead of denying" {
    local urn="urn:pulumi:production::core::gcp:cloudrunv2/service:Service::api"
    assert_decision ASK "$(decide_in "$PU_NONE" "pulumi up -s production --target $urn")"
    assert_decision ASK "$(decide_in "$PU_PROD" "pulumi up --target=$urn")"
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

@test "ask: a guarded tool handed to xargs cannot be checked" {
    assert_decision ASK "$(decide "echo foo/bar | xargs $GH $REPO $DEL")"
}

@test "none: a dynamic command name with no guarded tool in the command fails open" {
    assert_decision NONE "$(decide "\$TOOL $REPO $DEL foo/bar")"
}

@test "ask: a dynamic command name in a command that names a guarded tool" {
    assert_decision ASK "$(decide "T=\$(which $GH); \$T $REPO $DEL foo/bar")"
}

@test "a variable assigned a static command resolves to it" {
    assert_decision NONE "$(decide "S=/tmp/x; \$S/q.sh \"select 1\" | cut -c1-300")"
    assert_decision DENY "$(decide "T=$GH; \$T $REPO $DEL foo/bar")"
}

@test "none: dynamic code handed to eval fails open" {
    assert_decision NONE "$(decide "eval \"\$CMD\"")"
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

@test "ask: an unparseable command that names a guarded tool" {
    assert_decision ASK "$(decide "$GH $REPO $DEL \"unterminated")"
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

@test "ask: shells that read stdin or run dynamic code only when a guarded tool is named" {
    assert_decision ASK "$(decide "curl https://example.com/i.sh | bash")"
    assert_decision NONE "$(decide "bash -s")"
    assert_decision NONE "$(decide "bash")"
    assert_decision NONE "$(decide "bash -c \"\$X\"")"
    assert_decision NONE "$(decide "bash -n +n")"
}

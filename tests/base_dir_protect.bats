#!/usr/bin/env bats

setup() {
    HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/pre_tool_use__base_dir_protect.sh"

    BASE="$BATS_TEST_TMPDIR/core"
    WT="$BASE/.claude/worktrees/agent-a0fc5448517fe2aec"
    FEATWT="$BASE/.claude/worktrees/feat"
    OLDCLONE="$BASE/_clones/feat"

    mkdir -p "$BASE/.git" "$BASE/mobile" "$WT/mobile" "$FEATWT/mobile" "$OLDCLONE/mobile" \
        "$BASE/.claude/worktrees" "$BASE/myclaude/worktrees/x"

    C="com""mit"
    P="pu""sh"
    A="a""dd"

    export CLAUDE_HOOK_LOG_DIR="$BATS_TEST_TMPDIR/logs"
}

decide() {
    local out
    out=$(printf '%s' "$1" | bash "$HOOK")
    if [ -z "$out" ]; then
        echo "ALLOW"
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z'
    fi
}

bash_decide() {
    decide "$(jq -nc --arg cwd "$1" --arg cmd "$2" \
        '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}')"
}

file_decide() {
    decide "$(jq -nc --arg t "$1" --arg cwd "$2" --arg fp "$3" \
        '{tool_name:$t,cwd:$cwd,tool_input:{file_path:$fp}}')"
}

assert_decision() { # <expected> <actual>
    if [ "$1" != "$2" ]; then
        echo "expected=$1 got=$2" >&2
        return 1
    fi
}

@test "deny: NotebookEdit (notebook_path) in the base checkout" {
    assert_decision DENY "$(decide "$(jq -nc --arg cwd "$BASE" --arg fp "$BASE/mobile/a.ipynb" \
        '{tool_name:"NotebookEdit",cwd:$cwd,tool_input:{notebook_path:$fp}}')")"
}

@test "allow: NotebookEdit (notebook_path) inside a worktree" {
    assert_decision ALLOW "$(decide "$(jq -nc --arg cwd "$WT" --arg fp "$WT/mobile/a.ipynb" \
        '{tool_name:"NotebookEdit",cwd:$cwd,tool_input:{notebook_path:$fp}}')")"
}

@test "allow: Write a nested file inside an agent worktree" {
    assert_decision ALLOW "$(file_decide Write "$WT" "$WT/mobile/foo.ts")"
}

@test "allow: Edit a file at the agent worktree root" {
    assert_decision ALLOW "$(file_decide Edit "$WT" "$WT/README.md")"
}

@test "allow: git write with cwd = agent worktree root" {
    assert_decision ALLOW "$(bash_decide "$WT" "git $C -m x")"
}

@test "allow: git write with cwd = agent worktree subdir" {
    assert_decision ALLOW "$(bash_decide "$WT/mobile" "git $P -u origin br")"
}

@test "allow: git -C <worktree> from base repo cwd" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git -C $WT $A -A")"
}

@test "allow: cd <worktree> then git write, from base repo cwd" {
    assert_decision ALLOW "$(bash_decide "$BASE" "cd $WT && git $C -m x")"
}

@test "allow: read-only git status in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git status")"
}

@test "allow: checkout -f main in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git checkout -f main")"
}

@test "allow: checkout -f master in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git checkout -f master")"
}

@test "allow: reset --hard origin/main in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git reset --hard origin/main")"
}

@test "allow: clean -fd in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git clean -fd")"
}

@test "allow: clean -xfd (flag order/case with -x) in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git clean -xfd")"
}

@test "allow: the full base-repo sync sequence chained together" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git checkout -f main && git fetch origin --prune && git reset --hard origin/main && git clean -fd")"
}

@test "deny: checkout of a non-default branch in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git checkout -f some-other-branch")"
}

@test "deny: checkout with a pathspec in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git checkout -f main -- mobile/foo.ts")"
}

@test "deny: checkout main without -f in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git checkout main")"
}

@test "deny: reset --hard to a local branch in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git reset --hard some-local-branch")"
}

@test "deny: reset --hard to a bare SHA in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git reset --hard HEAD~1")"
}

@test "deny: reset --hard origin/main plus a trailing pathspec in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git reset --hard origin/main -- mobile/foo.ts")"
}

@test "deny: reset --soft origin/main in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git reset --soft origin/main")"
}

@test "deny: clean -f alone (no -d) in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git clean -f")"
}

@test "deny: clean -fd with a path argument in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git clean -fd mobile/")"
}

@test "allow: Write a nested file inside a feature worktree" {
    assert_decision ALLOW "$(file_decide Write "$FEATWT" "$FEATWT/mobile/foo.ts")"
}

@test "allow: git write with cwd = feature worktree root" {
    assert_decision ALLOW "$(bash_decide "$FEATWT" "git $C -m x")"
}

@test "allow: git -C <feature worktree> from base repo cwd" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git -C $FEATWT $A -A")"
}

@test "deny: Write to base repo README.md" {
    assert_decision DENY "$(file_decide Write "$BASE" "$BASE/README.md")"
}

@test "deny: Write to base repo mobile/foo.ts" {
    assert_decision DENY "$(file_decide Write "$BASE" "$BASE/mobile/foo.ts")"
}

@test "deny: Edit base repo .claude/settings.json" {
    assert_decision DENY "$(file_decide Edit "$BASE" "$BASE/.claude/settings.json")"
}

@test "deny: git write in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git $C -m x")"
}

@test "deny: git push in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git $P")"
}

@test "deny: git -C <base repo> issued from inside a worktree" {
    assert_decision DENY "$(bash_decide "$WT" "git -C $BASE $C -m x")"
}

@test "deny: cd out of the worktree, then git write" {
    assert_decision DENY "$(bash_decide "$WT" "cd $BASE && git $C -m x")"
}

@test "deny: file edit in the worktrees CONTAINER dir" {
    assert_decision DENY "$(file_decide Write "$BASE" "$BASE/.claude/worktrees/NOTES.md")"
}

@test "deny: git write with cwd = the worktrees CONTAINER dir" {
    assert_decision DENY "$(bash_decide "$BASE/.claude/worktrees" "git $C -m x")"
}

@test "deny: the retired _clones location is no longer an escape hatch (file edit)" {
    assert_decision DENY "$(file_decide Write "$BASE" "$OLDCLONE/mobile/foo.ts")"
}

@test "deny: the retired _clones location is no longer an escape hatch (git write)" {
    assert_decision DENY "$(bash_decide "$OLDCLONE" "git $C -m x")"
}

@test "deny: lookalike myclaude/worktrees file path" {
    assert_decision DENY "$(file_decide Write "$BASE" "$BASE/myclaude/worktrees/x/foo.ts")"
}

@test "deny: lookalike myclaude/worktrees as git cwd" {
    assert_decision DENY "$(bash_decide "$BASE/myclaude/worktrees/x" "git $C -m x")"
}

@test "deny: eval bypass, even from inside a worktree" {
    assert_decision DENY "$(bash_decide "$WT" "eval 'git $C -m x'")"
}

@test "deny: bash -c bypass, even from inside a worktree" {
    assert_decision DENY "$(bash_decide "$WT" "bash -c 'git $C -m x'")"
}

@test "allow: commit message containing a parenthetical git -C phrase" {
    cmd="git $C -m \"Combined with the harness isolation guard (which refuses a git -C pointing outside the worktree), agents could write nowhere.\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: commit message containing the literal words git commit" {
    cmd="git $C -m \"docs: explain when to run git $C and git $P\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: commit message containing a pipe and a parenthetical git phrase" {
    cmd="git $C -m \"note: a | b (and then git $C -m x) is prose\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: single-quoted argument containing a literal \$(git ...) string" {
    cmd="git $C -m 'the docs show \$(git -C $BASE $C -m x) as an example'"
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: heredoc body containing git prose, in a worktree" {
    cmd="git $C -F - <<'EOF'
refactor: rework the guard

Prose in the body (git -C $BASE $C -m x) is documentation, not a command.
EOF"
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: heredoc body containing git prose, with no git write at all" {
    cmd="cat <<'EOF' > $BASE/../notes.md
Docs mention (git -C $BASE $C -m x) purely as an example.
EOF"
    assert_decision ALLOW "$(bash_decide "$BASE" "$cmd")"
}

@test "allow: commit message built from a non-git command substitution" {
    cmd="git $C -m \"release \$(date +%Y-%m-%d)\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: prose-heavy commit message followed by a real push" {
    cmd="git $C -m \"fix: handle the (git -C x) case\" && git $P"
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "deny: \$(git -C <base>) substitution in command position" {
    cmd="\$(git -C $BASE $C -m x)"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: \$(git -C <base>) substitution with no trailing args" {
    cmd="\$(git -C $BASE $C)"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: \$(git -C <base>) substitution nested in a double-quoted string" {
    cmd="echo \"result: \$(git -C $BASE $C -m x)\""
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: backtick git -C <base> substitution" {
    cmd="echo \`git -C $BASE $C -m x\`"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: backtick git -C <base> substitution inside double quotes" {
    cmd="echo \"out: \`git -C $BASE $C -m x\`\""
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: subshell grouping that cds to the base repo" {
    cmd="(cd $BASE && git $C -m x)"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: subshell git write is refused even when it targets the worktree" {
    cmd="\$(git -C $WT $C -m x)"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "allow: commit message interpolating a READ-ONLY git substitution" {
    cmd="git $C -m \"\$(git log -1 --format=%s)\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: read-only substitution with a write word elsewhere in the command" {
    cmd="MSG=\$(git log -1 --format=%B)   # reconstruct the real $C message
echo \"\$MSG\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: read-only substitution assigned in the base repo" {
    cmd="TOP=\$(git rev-parse --show-toplevel) && echo \"$C target: \$TOP\""
    assert_decision ALLOW "$(bash_decide "$BASE" "$cmd")"
}

@test "deny: read-only substitution followed by a real base-repo git -C write" {
    cmd="\$(git log -1) && git -C $BASE $C -m x"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: read-only substitution, then cd to base repo, then git write" {
    cmd="\$(git rev-parse HEAD) && cd $BASE && git $C -m x"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: bash -c with a double-quoted git write, nested in a substitution" {
    cmd="\$(bash -c \"git -C $BASE $C -m x\")"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: bash -c with a single-quoted git write, nested in a substitution" {
    cmd="\$(bash -c 'git -C $BASE $C -m x')"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: eval with a git write, nested in a substitution" {
    cmd="\$(eval \"git -C $BASE $C -m x\")"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: bash -c nested in a substitution inside a double-quoted string" {
    cmd="echo \"\$(bash -c 'git -C $BASE $C -m x')\""
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: bash -c inside a plain subshell grouping" {
    cmd="(bash -c \"git -C $BASE $C -m x\")"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: sh -c with a git write, nested in a substitution" {
    cmd="\$(sh -c \"git -C $BASE $C -m x\")"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: heredoc fed to a shell that runs a base-repo git write" {
    cmd="bash <<'EOF'
git -C $BASE $C -m x
EOF"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: command builtin prefix on a base-repo git write" {
    assert_decision DENY "$(bash_decide "$BASE" "command git $C -am y")"
}

@test "deny: git -c global flag before the subcommand" {
    assert_decision DENY "$(bash_decide "$BASE" "git -c user.name=x $C -am y")"
}

@test "deny: git --no-pager global flag before the subcommand" {
    assert_decision DENY "$(bash_decide "$BASE" "git --no-pager $C -am y")"
}

@test "deny: env builtin prefix on a base-repo git write" {
    assert_decision DENY "$(bash_decide "$BASE" "env git $C -am y")"
}

@test "deny: backslash-escaped leading git" {
    assert_decision DENY "$(bash_decide "$BASE" "\\git $C -am y")"
}

@test "deny: git --git-dir and --work-tree pointing elsewhere, cwd still the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git --git-dir=/tmp/other/.git --work-tree=/tmp/other $C -am y")"
}

@test "allow: command builtin prefix on a worktree-scoped git write still allowed" {
    assert_decision ALLOW "$(bash_decide "$WT" "command git $C -m x")"
}

@test "allow: git -c global flag on a worktree-scoped git write still allowed" {
    assert_decision ALLOW "$(bash_decide "$WT" "git -c user.name=x $C -m x")"
}

@test "allow: read-only git status survives command/env prefix stripping" {
    assert_decision ALLOW "$(bash_decide "$BASE" "command git status")"
}

@test "deny: file path that traverses out of a worktree back into the base repo" {
    assert_decision DENY "$(file_decide Write "$BASE" "$WT/../../../README.md")"
}

@test "deny: file path that traverses out of a worktree into a base-repo subdir" {
    assert_decision DENY "$(file_decide Write "$BASE" "$FEATWT/../../../mobile/foo.ts")"
}

@test "deny: a single-dot-padded traversal out of a worktree" {
    assert_decision DENY "$(file_decide Write "$BASE" "$WT/./mobile/../../../../README.md")"
}

@test "allow: a relative file path inside a worktree, resolved against cwd" {
    assert_decision ALLOW "$(file_decide Write "$WT" "mobile/foo.ts")"
}

@test "allow: a .. that stays inside the worktree" {
    assert_decision ALLOW "$(file_decide Write "$WT" "$WT/mobile/../mobile/foo.ts")"
}

@test "deny: git --paginate before the subcommand" {
    assert_decision DENY "$(bash_decide "$BASE" "git --paginate $C -am y")"
}

@test "deny: git tag (creates a ref, was never on the denylist)" {
    assert_decision DENY "$(bash_decide "$BASE" "git tag release-x")"
}

@test "deny: git update-ref (writes a ref directly)" {
    assert_decision DENY "$(bash_decide "$BASE" "git update-ref refs/heads/main HEAD")"
}

@test "deny: git notes add" {
    assert_decision DENY "$(bash_decide "$BASE" "git notes $A -m x")"
}

@test "deny: git config set" {
    assert_decision DENY "$(bash_decide "$BASE" "git config user.name attacker")"
}

@test "deny: git remote add" {
    assert_decision DENY "$(bash_decide "$BASE" "git remote $A evil https://example.com/x.git")"
}

@test "deny: git branch that CREATES a branch" {
    assert_decision DENY "$(bash_decide "$BASE" "git branch brand-new-branch")"
}

@test "deny: an unknown future git subcommand fails safe" {
    assert_decision DENY "$(bash_decide "$BASE" "git some-future-subcommand --do-it")"
}

@test "deny: git -c alias.X= override, which can redefine any name as a write" {
    assert_decision DENY "$(bash_decide "$BASE" "git -c alias.zz=$C zz -m x")"
}

@test "deny: git -c include.path= override" {
    assert_decision DENY "$(bash_decide "$BASE" "git -c include.path=/tmp/evil.cfg status")"
}

@test "deny: a -c alias override is not laundered by pointing -C at a worktree" {
    assert_decision DENY "$(bash_decide "$BASE" "git -C $WT -c alias.zz=$C zz -m x")"
}

@test "deny: builtin wrapper prefix on a base-repo git write" {
    assert_decision DENY "$(bash_decide "$BASE" "builtin command git $C -am y")"
}

@test "deny: exec prefix on a base-repo git write" {
    assert_decision DENY "$(bash_decide "$BASE" "exec git $C -am y")"
}

@test "deny: absolute path to the git binary" {
    assert_decision DENY "$(bash_decide "$BASE" "/usr/bin/git $C -am y")"
}

@test "deny: env with an argument-taking flag before git" {
    assert_decision DENY "$(bash_decide "$BASE" "env -u FOO git $C -am y")"
}

@test "allow: git log in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git log --oneline -5")"
}

@test "allow: git diff in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git diff --stat")"
}

@test "allow: git show in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git show HEAD")"
}

@test "allow: git rev-parse in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git rev-parse --show-toplevel")"
}

@test "allow: bare git branch (a listing) in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git branch")"
}

@test "allow: git branch with read-only flags in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git branch -a --sort=-committerdate")"
}

@test "allow: git fetch in the base repo (touches only remote-tracking refs)" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git fetch --all")"
}

@test "allow: git worktree list from the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git worktree list")"
}

@test "deny: direct git worktree writes from the base repo (only the worktree scripts may run them)" {
    assert_decision DENY "$(bash_decide "$BASE" "git worktree $A .claude/worktrees/x -b x")"
    assert_decision DENY "$(bash_decide "$BASE" "git worktree remove .claude/worktrees/x")"
    assert_decision DENY "$(bash_decide "$BASE" "git worktree prune")"
}

@test "allow: git branch --list/-v/--merged with a pattern in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git branch --list 'worktree-agent-*'")"
    assert_decision ALLOW "$(bash_decide "$BASE" "git branch -l 'feat-*'")"
    assert_decision ALLOW "$(bash_decide "$BASE" "git branch -v 'feat-*'")"
    assert_decision ALLOW "$(bash_decide "$BASE" "git branch --merged main 'feat-*'")"
}

@test "deny: git branch with a name but no list flag in the base repo" {
    assert_decision DENY "$(bash_decide "$BASE" "git branch newb")"
    assert_decision DENY "$(bash_decide "$BASE" "git branch -a newb")"
    assert_decision DENY "$(bash_decide "$BASE" "git branch -m old new")"
    assert_decision DENY "$(bash_decide "$BASE" "git branch --list -D foo")"
}

@test "allow: read-only git after a cd that may fail, with a branch pattern" {
    assert_decision ALLOW "$(bash_decide "$BASE" "cd $BASE/.claude/worktrees/missing && git worktree list | grep x; git branch --list 'wt-*'; git log origin/main..HEAD --oneline | head")"
}

@test "ask: git write after a cd that may fail" {
    assert_decision ASK "$(bash_decide "$BASE" "cd $BASE/.claude/worktrees/missing && true; git commit -m x")"
}

@test "allow: git config --get in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git config --get user.email")"
}

@test "allow: git stash list in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git stash list")"
}

@test "allow: git ls-files piped into a reader" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git ls-files | head -20")"
}

@test "allow: every newly-gated write still works inside a worktree" {
    assert_decision ALLOW "$(bash_decide "$WT" "git tag release-x")"
    assert_decision ALLOW "$(bash_decide "$WT" "git branch brand-new-branch")"
    assert_decision ALLOW "$(bash_decide "$WT" "git config user.name me")"
}

@test "deny: brace group around a base-repo git write" {
    assert_decision DENY "$(bash_decide "$BASE" "{ git $C -am y; }")"
}

@test "deny: if/then around a base-repo git write" {
    assert_decision DENY "$(bash_decide "$BASE" "if true; then git $C -am y; fi")"
}

@test "deny: while/do around a base-repo git write" {
    assert_decision DENY "$(bash_decide "$BASE" "while true; do git $C -am y; done")"
}

@test "deny: for/do around a base-repo git write" {
    assert_decision DENY "$(bash_decide "$BASE" "for i in 1; do git $C -am y; done")"
}

@test "deny: unquoted heredoc delimiter whose body runs a git write" {
    cmd="cat <<EOF
\$(git -C $BASE $C -m x)
EOF"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: unquoted heredoc delimiter with a backtick substitution" {
    cmd="cat <<EOF
\`git -C $BASE $C -m x\`
EOF"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "allow: QUOTED heredoc delimiter keeps the same body inert" {
    cmd="cat <<'EOF'
\$(git -C $BASE $C -m x)
EOF"
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: double-quoted heredoc delimiter is inert too" {
    cmd="cat <<\"EOF\"
\$(git -C $BASE $C -m x)
EOF"
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: unquoted heredoc whose body is only prose" {
    cmd="git $C -F - <<EOF
refactor: rework the guard

Prose in the body (git -C $BASE $C -m x) is documentation, not a command.
EOF"
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "deny: bash -c with trailing argv after the code string" {
    assert_decision DENY "$(bash_decide "$WT" "bash -c \"git -C $BASE $C -m x\" sentinel")"
}

@test "deny: bash -lc with combined short flags" {
    assert_decision DENY "$(bash_decide "$WT" "bash -lc \"git -C $BASE $C -m x\"")"
}

@test "deny: an absolute path to the interpreter" {
    assert_decision DENY "$(bash_decide "$WT" "/bin/bash -c \"git -C $BASE $C -m x\"")"
}

@test "allow: a realistically long commit message stays well inside the bounds" {
    local body=""
    local i
    for i in $(seq 1 40); do
        body="$body This is sentence $i of a perfectly ordinary (and quite wordy) commit message."
    done
    assert_decision ALLOW "$(bash_decide "$WT" "git $C -m \"refactor: something real.$body\"")"
}

@test "allow: a separator and a git write inside an echoed string in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "echo \"x; git $C -m y\"")"
}

@test "allow: a quoted cat heredoc that mentions a forced push in the base repo" {
    assert_decision ALLOW "$(bash_decide "$BASE" "cat <<'EOF'
git $P --force
EOF")"
}

@test "deny: a subshell push is refused even from a worktree" {
    assert_decision DENY "$(bash_decide "$WT" "(git $P)")"
}

@test "deny: bash -c push is refused even from a worktree" {
    assert_decision DENY "$(bash_decide "$WT" "bash -c \"git $P\"")"
}

@test "deny: git config keys are case-insensitive, so an Alias override is still unsafe" {
    assert_decision DENY "$(bash_decide "$BASE" "git -C $WT -c Alias.zz=$C zz -m x")"
}

@test "deny: --git-dir pointing at the base repo from a worktree" {
    assert_decision DENY "$(bash_decide "$WT" "git --git-dir=$BASE/.git $C -m x")"
}

@test "ask: a git write after a dynamic cd cannot be placed" {
    assert_decision ASK "$(bash_decide "$WT" "cd \"\$DIR\" && git $C -m x")"
}

@test "ask: a git write after a cd that may have failed could land in the base repo" {
    assert_decision ASK "$(bash_decide "$BASE" "cd $WT/mobile; git $C -m x")"
    assert_decision ASK "$(bash_decide "$BASE" "cd $WT && git $A -A; git $P")"
}

@test "allow: a cd that may have failed when every candidate directory is a worktree" {
    assert_decision ALLOW "$(bash_decide "$WT" "cd mobile; git $C -m x")"
    assert_decision ALLOW "$(bash_decide "$WT" "cd $FEATWT
git $C -m x")"
}

@test "allow: cd into a worktree subdir with && keeps the directory known" {
    assert_decision ALLOW "$(bash_decide "$BASE" "cd $WT/mobile && git $C -m x")"
}

@test "allow: an unparseable command fails open" {
    assert_decision ALLOW "$(bash_decide "$BASE" "echo \"unterminated")"
}

@test "allow: scratchpad scripts run through a variable assigned in the same command" {
    local sp="$BATS_TEST_TMPDIR/scratchpad"
    assert_decision ALLOW "$(bash_decide "$BASE" "S=$sp; mkdir -p \$S/ks && cp -R /tmp/a \$S/ks && cd \$S/ks && sed -i '' 's/a/b/' \$S/q.sh && \$S/q.sh \"select 1\" | cut -c1-300")"
    assert_decision ALLOW "$(bash_decide "$BASE" "S=$sp; sed -i '' 's#a#b#' \$S/q.sh; \$S/q.sh \"select x\" | cut -c1-300")"
    assert_decision ALLOW "$(bash_decide "$BASE" "S=$sp; \$S/q.sh \"select 1\" ; echo; \$S/q.sh \"a\"; \$S/q.sh \"b\"")"
    assert_decision ALLOW "$(bash_decide "$BASE" "S=$sp; \$S/q.sh \"select 1\" | cut -c1-6000")"
    assert_decision ALLOW "$(bash_decide "$BASE" "S=$sp; \$S/qs.sh \"select a->>'b', c::int from t where d ~ 'x' and e > 2 and (f)\" ; \$S/qs.sh \"select 1 > 0\"; \$S/qs.sh 'a < b'; \$S/q.sh \"x >> y\"")"
}

@test "allow: a variable holding a static command line runs inside a worktree" {
    assert_decision ALLOW "$(bash_decide "$BASE" "cd $WT && U=abc; A=\"node node_modules/cli.js run\"; \$A gesture-tap --udid \$U >/dev/null; date -u +%FT%TZ; \$A describe | jq . | head -50")"
}

@test "allow: unresolvable command words fail open" {
    assert_decision ALLOW "$(bash_decide "$BASE" "A=\"\$UNKNOWN\"; \$A x")"
    assert_decision ALLOW "$(bash_decide "$BASE" "\$TOOL run; eval \"\$CMD\"; echo x | xargs rm")"
}

@test "allow: writes outside any repo or inside a worktree" {
    : >"$FEATWT/.git"
    assert_decision ALLOW "$(bash_decide "$BASE" "echo x > /tmp/out; touch $BATS_TEST_TMPDIR/f; echo y >/dev/null 2>&1")"
    assert_decision ALLOW "$(bash_decide "$BASE" "echo x > $WT/f; sed -i '' s/a/b/ $WT/mobile/g; cp a $FEATWT/")"
    assert_decision ALLOW "$(bash_decide "$WT" "echo x > f && rm -f mobile/x")"
}

@test "deny: file writes into the base repo outside a worktree" {
    assert_decision DENY "$(bash_decide "$BASE" "echo hi > README.md")"
    assert_decision DENY "$(bash_decide "/tmp" "cd $BASE && rm -f AGENTS.md")"
    assert_decision DENY "$(bash_decide "/tmp" "S=$BASE; cp /tmp/x \$S/AGENTS.md")"
    assert_decision DENY "$(bash_decide "$BASE" "sed -i '' s/a/b/ mobile/x.sh")"
    assert_decision DENY "$(bash_decide "$WT" "echo x | tee -a $BASE/log")"
    assert_decision DENY "$(bash_decide "$WT" "{ echo a; echo b; } > $BASE/out")"
    assert_decision DENY "$(bash_decide "$WT" "mv $BASE/a /tmp/a")"
    assert_decision DENY "$(bash_decide "$WT" "perl -pi -e s/x/y/ $BASE/f")"
    assert_decision DENY "$(bash_decide "$WT" "dd if=/dev/zero of=$BASE/f count=1")"
    assert_decision DENY "$(bash_decide "/tmp" "S=$BASE; \$S/run.sh > \$S/out")"
}

@test "allow: gitignored paths in a real repo, deny tracked content" {
    local repo="$BATS_TEST_TMPDIR/real"
    git init -q "$repo"
    printf 'build/\n' >"$repo/.gitignore"
    assert_decision ALLOW "$(bash_decide "$repo" "mkdir -p build && echo x > build/out.txt")"
    assert_decision DENY "$(bash_decide "$repo" "echo x > src.txt")"
}

@test "allow: git writes in a directory that is not inside any repo" {
    local scratch="$BATS_TEST_TMPDIR/scratch"
    mkdir -p "$scratch"
    assert_decision ALLOW "$(bash_decide "$scratch" "git init -q x && git -C x $C --allow-empty -m x")"
}

@test "ask: a file write whose directory may be the base repo" {
    assert_decision ASK "$(bash_decide "$BASE" "cd $WT; echo x > f")"
}

@test "allow: a variable re-assigned later is not trusted to resolve a write target" {
    assert_decision ALLOW "$(bash_decide "$BASE" "S=/tmp; S=\$X; echo > \$S/f")"
    assert_decision ALLOW "$(bash_decide "$BASE" "for S in a; do :; done; echo > \$S/f")"
}

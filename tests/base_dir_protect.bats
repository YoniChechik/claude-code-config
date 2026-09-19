#!/usr/bin/env bats
#
# Verification matrix for the base-dir-protect PreToolUse guard
# (scripts/pre_tool_use__base_dir_protect.sh).
#
# Every case feeds a real hook-input JSON payload to the real hook script and
# asserts the permission decision, so the guard is exercised exactly the way the
# harness exercises it.
#
# The suite is deliberately two-sided, because this guard has two failure modes
# that pull in opposite directions:
#
#   - too strict -> it denies legitimate work. The guard matches the LITERAL TEXT
#     of a bash command, so prose inside a commit message or a heredoc body used
#     to read as executable git. A commit was once denied purely because its
#     message contained the phrase "(which refuses git -C pointing outside...)".
#
#   - too loose  -> it lets a git write reach the base repo. The command
#     substitution cases below are the ones that must never regress: `$(...)`
#     still executes inside DOUBLE quotes, so double-quoted spans cannot simply
#     be ignored the way single-quoted spans and heredoc bodies can.
#
# Fixtures are built in $BATS_TEST_TMPDIR rather than pointed at a real checkout,
# because the hook resolves `cd` and `git -C` targets with a real `cd`, and the
# file-edit branch walks up looking for a `.git` marker.
#
# The git write subcommand tokens are assembled at runtime (C="com""mit"), so
# this file's own text cannot trip the guard if the suite is ever launched from a
# shell one-liner that the guard gets to inspect.

setup() {
    HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/pre_tool_use__base_dir_protect.sh"

    BASE="$BATS_TEST_TMPDIR/core"
    # Harness agent worktree and /create-worktree feature worktree — both live under
    # the same <repo>/.claude/worktrees/ container and get identical treatment.
    WT="$BASE/.claude/worktrees/agent-a0fc5448517fe2aec"
    FEATWT="$BASE/.claude/worktrees/feat"
    # The retired clone location. Kept as a fixture purely to pin that it is now DENIED.
    OLDCLONE="$BASE/_clones/feat"

    # `.git` marker makes $BASE look like a real repo to the file-edit branch;
    # without it every path under it counts as "outside a git repo" and is allowed.
    mkdir -p "$BASE/.git" "$BASE/mobile" "$WT/mobile" "$FEATWT/mobile" "$OLDCLONE/mobile" \
        "$BASE/.claude/worktrees" "$BASE/myclaude/worktrees/x"

    C="com""mit"
    P="pu""sh"
    A="a""dd"
}

# decide <payload-json> -> ALLOW | DENY
decide() {
    local out
    out=$(printf '%s' "$1" | bash "$HOOK")
    if [ -z "$out" ]; then
        echo "ALLOW"
    else
        printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' | tr 'a-z' 'A-Z'
    fi
}

# bash_decide <cwd> <command> -> ALLOW | DENY
bash_decide() {
    decide "$(jq -nc --arg cwd "$1" --arg cmd "$2" \
        '{tool_name:"Bash",cwd:$cwd,tool_input:{command:$cmd}}')"
}

# file_decide <tool_name> <cwd> <file_path> -> ALLOW | DENY
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

# =============================================================================
# ALLOWED: worktrees under <repo>/.claude/worktrees/ are the ONLY legitimate
# isolated workspace — both harness agent worktrees and /create-worktree feature
# worktrees.
# =============================================================================

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

@test "allow: Write a nested file inside a feature worktree" {
    assert_decision ALLOW "$(file_decide Write "$FEATWT" "$FEATWT/mobile/foo.ts")"
}

@test "allow: git write with cwd = feature worktree root" {
    assert_decision ALLOW "$(bash_decide "$FEATWT" "git $C -m x")"
}

@test "allow: git -C <feature worktree> from base repo cwd" {
    assert_decision ALLOW "$(bash_decide "$BASE" "git -C $FEATWT $A -A")"
}

# =============================================================================
# DENIED: the base repo working tree
# =============================================================================

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

# =============================================================================
# DENIED: lookalike paths and shell-level bypasses
# =============================================================================

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

# =============================================================================
# ALLOWED: prose is not code. Quoted text and heredoc bodies never execute, so
# they must not be read as a git invocation. These are the false positives the
# sanitizer fixes; every one of them was DENIED before it existed.
# =============================================================================

@test "allow: commit message containing a parenthetical git -C phrase" {
    # The exact real-world failure: a commit message describing the guard itself.
    cmd="git $C -m \"Combined with the harness isolation guard (which refuses a git -C pointing outside the worktree), agents could write nowhere.\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: commit message containing the literal words git commit" {
    cmd="git $C -m \"docs: explain when to run git $C and git $P\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: commit message containing a pipe and a parenthetical git phrase" {
    # The pipe splits the message across segments; the fragment starting with `(`
    # used to look like a subshell lead.
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

# =============================================================================
# DENIED: real command substitutions. `$(...)` and backticks execute, including
# inside double quotes, so the sanitizer must keep them. A regression here is a
# real bypass, not a papercut.
# =============================================================================

@test "deny: \$(git -C <base>) substitution in command position" {
    cmd="\$(git -C $BASE $C -m x)"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: \$(git -C <base>) substitution with no trailing args" {
    # Pins the `)` boundary: the subcommand is the last token before the paren.
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
    # Pinned conservative behaviour: a git write reached through a substitution is
    # denied on sight, without trusting the -C target.
    cmd="\$(git -C $WT $C -m x)"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "allow: commit message interpolating a READ-ONLY git substitution" {
    # The write check is scoped to the inside of the span, so a `git log` span no
    # longer inherits the guilt of a `commit` sitting outside it.
    cmd="git $C -m \"\$(git log -1 --format=%s)\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: read-only substitution with a write word elsewhere in the command" {
    # The case that bit a live session: \$(git log ...) plus the word "commit"
    # appearing in an unrelated comment.
    cmd="MSG=\$(git log -1 --format=%B)   # reconstruct the real $C message
echo \"\$MSG\""
    assert_decision ALLOW "$(bash_decide "$WT" "$cmd")"
}

@test "allow: read-only substitution assigned in the base repo" {
    cmd="TOP=\$(git rev-parse --show-toplevel) && echo \"$C target: \$TOP\""
    assert_decision ALLOW "$(bash_decide "$BASE" "$cmd")"
}

# =============================================================================
# DENIED: a write OUTSIDE a substitution span is not the span scan's job — the
# per-segment scan owns it, and these pin that hand-off.
# =============================================================================

@test "deny: read-only substitution followed by a real base-repo git -C write" {
    cmd="\$(git log -1) && git -C $BASE $C -m x"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

@test "deny: read-only substitution, then cd to base repo, then git write" {
    cmd="\$(git rev-parse HEAD) && cd $BASE && git $C -m x"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

# =============================================================================
# DENIED: `eval` / `sh -c` arguments are CODE, not data. A shell re-parses that
# quoted string, so the sanitizer must keep it. Nested inside a substitution
# these dodge the segment-anchored eval / -c checks entirely, which makes the
# span scan the only thing in their way.
# =============================================================================

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
    # The body IS executed here, but the plain per-segment scan catches the write
    # line on its own merits.
    cmd="bash <<'EOF'
git -C $BASE $C -m x
EOF"
    assert_decision DENY "$(bash_decide "$WT" "$cmd")"
}

# =============================================================================
# DENIED: prefix-wrapper bypasses of GIT_WRITE_PATTERN, closed by the shared
# _shell_command_guard.sh normalization (_strip_leading_wrappers /
# _strip_git_global_flags). Every one of these silently ALLOWED before that
# library existed — this is the exact bypass list from the security review.
# =============================================================================

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

# =============================================================================
# PATH TRAVERSAL on the file-edit branch. The worktree check used to run on the
# RAW file_path string, so a path that spells out a worktree prefix and then
# climbs back out of it matched character for character while pointing at the
# base repo. Every one of these must DENY.
# =============================================================================

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

# =============================================================================
# GIT ALLOWLIST. The old denylist named a handful of write subcommands, so every
# subcommand it had not heard of wrote to the base repo unchallenged. The model
# is inverted: only known-read subcommands pass.
# =============================================================================

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
    # An alias body can run ANY command, so -C is no evidence about what it does.
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
    # The env prefix stripper used to skip `-u` but not its argument, leaving
    # `FOO` in command position and the real git invocation unexamined.
    assert_decision DENY "$(bash_decide "$BASE" "env -u FOO git $C -am y")"
}

# --- and the read side of the allowlist must keep working in the base repo ---

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

@test "allow: git worktree, the sanctioned escape hatch, from the base repo" {
    # /create-worktree itself runs this from the base repo; denying it would
    # make the guard impossible to comply with.
    assert_decision ALLOW "$(bash_decide "$BASE" "git worktree list")"
    assert_decision ALLOW "$(bash_decide "$BASE" "git worktree $A .claude/worktrees/x -b x")"
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

# =============================================================================
# SHELL GRAMMAR. A command body wrapped in a brace group or an if/while/for
# construct is still a command; the segment splitter used to hand the guard a
# segment starting with `{` or `then` and give up on it.
# =============================================================================

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

# =============================================================================
# HEREDOCS. A QUOTED delimiter makes the body inert data; an UNQUOTED one still
# runs every substitution inside it before the body reaches stdin. Dropping both
# bodies meant `cat <<EOF` / `$(git commit)` / `EOF` produced no decision.
# =============================================================================

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

# =============================================================================
# SHELL-CODE ARGUMENTS. An end-anchored `-c "(.*)"$` match is defeated by a
# trailing argv word, by combined short flags, and by an absolute path to the
# interpreter.
# =============================================================================

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

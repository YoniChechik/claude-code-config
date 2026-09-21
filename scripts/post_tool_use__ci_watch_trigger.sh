#!/usr/bin/env bash
#
# PostToolUse:Bash hook — auto-launch the one-shot CI watcher.
#
# After a Bash tool call that (a) really succeeded and (b) matches one of a
# DELIBERATELY NARROW set of command shapes, this hook injects an instruction
# for CLAUDE (never the user) to start scripts/ci_watch.sh in
# the background for the branch the command acted on.
#
# The three triggers:
#   1. `git push` of the current branch, when that branch already has an OPEN
#      PR                                          -> push-mode watcher
#   2. `gh pr create` for the current branch       -> push-mode watcher
#   3. `gh pr merge` of the current branch's PR,
#      or of an explicitly named PR                -> merge-mode watcher
#
# Trigger contract (intentional limitation): a hook cannot reliably parse
# arbitrary shell. `cd elsewhere && git push`, `git -C other push`, a
# multi-ref push, a raw GraphQL mutation — none of those can be resolved from
# this hook's own cwd, so NONE of them trigger anything. BUT an explicit
# `--repo`/`-R owner/repo` on `gh pr create`/`gh pr merge`, and an explicit
# positional PR number/URL/branch on `gh pr merge`, ARE trusted outright
# instead of being treated as out of contract: the caller named that target
# directly, in a command that already succeeded, so there is nothing to
# verify it against cwd for — see shape_ok_create/shape_ok_merge below. The
# hook triggers on that explicit-target shape, or on the plain "current
# branch of the repo at the hook's cwd" shape, and silently skips everything
# else — there is no manual fallback, so a missed trigger means nobody
# launches a watcher at all.
#
# One carve-out to that "not ONE simple command" limitation (Step 3b): a
# `--body "$(cat <<'EOF' ... EOF )"` heredoc substitution with a QUOTED
# delimiter is provably inert (no expansion happens inside it at all), so it
# is neutralized to a placeholder before the shape checks run, rather than
# rejecting the whole command over its own internal `$(`/newlines. An
# UNQUOTED delimiter is NOT neutralized and still rejects the command, since
# its body can contain real `$(...)`/`` ` ``/`$VAR` expansion.
#
# Output is hookSpecificOutput.additionalContext ONLY — no systemMessage, so
# nothing is ever surfaced to the user. Every git/gh call the hook makes is
# time-boxed and FAILS OPEN: on any error, empty answer or timeout the hook
# logs one line and exits 0 without triggering. A flaky `gh` must never block
# or break the user's real command.

# --- Tunables / paths -------------------------------------------------------
# Both are env-overridable so the test suite can point the log somewhere else
# and shrink the time box without really waiting 5s.
: "${CLAUDE_NOTIFY_TMP_DIR:=/tmp}"
: "${CI_WATCH_HOOK_TIMEOUT:=5}"
HOOK_LOG="${CLAUDE_NOTIFY_TMP_DIR}/ci_watch2_hook.log"

# Resolved HERE, before Step 6 `cd`s into the tool call's cwd: after that cd a
# relative $BASH_SOURCE would resolve against the wrong directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Step 1: read stdin once (it can only be consumed a single time). --------
input=$(cat)

# --- Step 2: cheap early exit, zero subprocesses. ----------------------------
# The settings.json matcher for this hook is a bare "Bash", so it runs on EVERY
# Bash tool call. A plain `case` substring match on the raw JSON text rejects
# the overwhelmingly common irrelevant call for free; only a command that could
# possibly match Step 5's precise shapes pays for the jq/git/gh forks below.
case "$input" in
    *"git push"* | *"gh pr create"* | *"gh pr merge"* | *"createPullRequest"* | *"mergePullRequest"*) ;;
    *) exit 0 ;;
esac

# --- helpers ----------------------------------------------------------------

# One fail-open log line. Never writes to stdout: stdout is the hook's JSON
# channel, and a stray byte there is a protocol error.
hook_log() {
    printf '%s ci_watch_trigger: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$HOOK_LOG" 2>/dev/null
    return 0
}

# Run an EXTERNAL command with a hard time box, portably.
# `timeout`/`gtimeout` are GNU coreutils and are absent on a stock macOS, which
# is this repo's primary platform — so when neither exists we background the
# command in its own watchdog pair and TERM it ourselves. The watchdog's own
# stdout is closed off to /dev/null; otherwise it would hold the caller's
# command-substitution pipe open for the full time box even after the real
# command had already exited.
run_timeout() {
    local secs="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}s" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}s" "$@"
        return $?
    fi
    # Job control (`set -m`) puts the backgrounded command in a process group of
    # its own whose pgid is its pid, so the watchdog can signal the command AND
    # every child it spawned. That matters for more than tidiness: `gh` is
    # called inside a command substitution, and any surviving grandchild keeps
    # that substitution's pipe open for its whole lifetime — which would defeat
    # the time box entirely. Job control is switched back off immediately: the
    # child is already in its own group by then, and leaving it on would print
    # job-completion notices for the rest of the hook.
    local had_m=0
    case "$-" in *m*) had_m=1 ;; esac
    set -m
    "$@" &
    local pid=$!
    [ "$had_m" = "1" ] || set +m
    (
        local i
        for ((i = 0; i < secs; i++)); do
            kill -0 -- -"$pid" 2>/dev/null || exit 0
            sleep 1
        done
        kill -TERM -- -"$pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    local watchdog=$!
    local rc=0
    wait "$pid" || rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    return "$rc"
}

# --- Step 3: parse the PostToolUse payload. ---------------------------------
# Shape (per the hooks docs, and mirrored by every other hook in this repo):
#   { tool_name, tool_input: {command}, tool_response: {exit_code, stdout,
#     stderr}, cwd }
tool_name=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$tool_name" = "Bash" ] || exit 0

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
exit_code=$(printf '%s' "$input" | jq -r '.tool_response.exit_code // empty' 2>/dev/null)
tool_stdout=$(printf '%s' "$input" | jq -r '.tool_response.stdout // empty' 2>/dev/null)
tool_stderr=$(printf '%s' "$input" | jq -r '.tool_response.stderr // empty' 2>/dev/null)
CWD=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)

[ -n "$cmd" ] || exit 0

# --- Step 3b: neutralize safe, QUOTED-delimiter heredoc command substitutions. ---
# `--body "$(cat <<'EOF' ... EOF )"` -- this environment's own recommended
# shape for a multi-line PR body/commit message, precisely to dodge OTHER
# hooks' false-positives on git-words in prose -- trips Step 4c's "not ONE
# simple command" gate below for the wrong reason. `$(` and the heredoc's
# internal newlines ARE real metacharacters in general, but a SINGLE- or
# DOUBLE-quoted heredoc delimiter suppresses ALL expansion inside the body --
# no `$VAR`, no `$(...)`, no backtick -- so that body is inert literal text
# that cannot retarget the repo/branch, which is the actual risk Step 4c
# guards against. Replace each such heredoc substitution with an opaque,
# single-word placeholder BEFORE Step 4c/5 ever see the command, so the
# flag's VALUE still reads as exactly one token (matching how
# shape_ok_create/shape_ok_merge already skip over a --body/--title value)
# instead of poisoning the whole command's shape check. `/s` (DOTALL) lets
# `.` cross the heredoc's internal newlines; the non-greedy `.*?` stops at
# the FIRST line that is exactly the delimiter, matching real heredoc
# semantics. An UNQUOTED delimiter (`<<EOF`, real expansion happens inside
# the body) is deliberately NOT matched here and still falls through to Step
# 4c's rejection, unchanged -- this only neutralizes the provably-inert
# form. `\x27` stands in for a literal single-quote inside the perl
# character class, since the outer perl program is itself single-quoted in
# this shell command.
cmd_for_parsing=$(printf '%s' "$cmd" | perl -0777 -pe 's/\$\(\s*cat\s+<<-?\s*([\x27"])([A-Za-z_][A-Za-z0-9_]*)\1\s*\n.*?\n\s*\2\s*\n?\)/HEREDOC_LITERAL_BODY/gs' 2>/dev/null)
[ -n "$cmd_for_parsing" ] || cmd_for_parsing="$cmd"

# --- Step 4: the two universal gates. ---------------------------------------
# (a) The command must actually have SUCCEEDED. The hook this replaces never
#     checked, so it reproducibly fired on `gh pr merge --help`.
[ "$exit_code" = "0" ] || exit 0

# (b) A help invocation performs no action. The token boundaries matter: a
#     naive substring test would treat `git push origin push-harder` or
#     `git reset -hard` as a help call.
if printf '%s' "$cmd_for_parsing" | grep -qE '(^|[[:space:]])(-h|--help)([[:space:]]|=|$)'; then
    exit 0
fi

# (c) Anything that is not ONE simple command is out of contract: a pipeline, a
#     `&&` chain, a command substitution or a redirect can move the effective
#     repo/branch in ways this hook cannot follow. Checked against the
#     HEREDOC-NEUTRALIZED command (Step 3b) so a safe, literal multi-line
#     --body/--title value doesn't trip this on its own newlines/`$(` — any
#     OTHER `;`/`&`/`|`/backtick/`$(`/`>`/`<`/newline outside that one
#     recognized heredoc shape still rejects the command exactly as before.
# shellcheck disable=SC2016  # `$(` here is a literal two-byte pattern, not an expansion.
case "$cmd_for_parsing" in
    *";"* | *"&"* | *"|"* | *'`'* | *'$('* | *">"* | *"<"* | *$'\n'*) exit 0 ;;
esac

# --- Step 5a: which of the three triggers could this be? --------------------
# Tokenize into argv-shaped words. `read -a` only splits on IFS whitespace and
# has NO concept of quoting, so `gh pr create --title "flip all five DEV-746
# ..."` (any multi-word --title/--body/etc value -- the overwhelmingly common
# case for this hook) exploded into one token per word, which then failed
# shape_ok_create() on the very next bare word after `--title` and silently
# skipped the trigger. `xargs -n1` DOES honor single/double quotes the way the
# real shell that ran `$cmd_for_parsing` already did, which is all we need --
# every metacharacter that would make a fuller shell-grammar parse necessary
# ($(), backtick, `;`, `&`, `|`, redirects, newlines) was already rejected by
# Step 4c above (on the heredoc-neutralized command, Step 3b), and xargs
# performs no `$VAR`/`~` expansion or globbing, so a literal token is exactly
# what comes out. Tokenizing `cmd_for_parsing` rather than the original
# `cmd` means a neutralized `--body "HEREDOC_LITERAL_BODY"` reads as one
# clean value token, exactly like any other quoted --body string already did.
if ! tokens_str=$(printf '%s' "$cmd_for_parsing" | xargs -n1 2>/dev/null); then
    hook_log "could not tokenize command (unbalanced quoting?); skipping: $cmd"
    exit 0
fi
tokens=()
while IFS= read -r line; do
    tokens+=("$line")
done <<<"$tokens_str"

KIND=""     # the ci_watch.sh mode to launch: push | merge
ACTION=""   # which trigger matched, for the message's opening sentence
case "${tokens[0]:-} ${tokens[1]:-} ${tokens[2]:-}" in
    "git push "*) KIND="push"; ACTION="push" ;;
    "gh pr create") KIND="push"; ACTION="create" ;;
    "gh pr merge") KIND="merge"; ACTION="merge" ;;
    *) exit 0 ;;
esac

# --- Step 5b: a no-op push has nothing to watch. ----------------------------
if [ "$ACTION" = "push" ]; then
    case "$tool_stdout$tool_stderr" in
        *"Everything up-to-date"*) exit 0 ;;
    esac
fi

# --- Step 6: resolve the current branch from the hook's OWN cwd. ------------
# `cd` rather than `git -C`, because `gh` resolves its repo from the process
# cwd too and must see the same directory the tool call ran in.
#
# Needed for push and create unconditionally (their target IS "the current
# branch of the repo at cwd", even when create's PR lands in an explicit
# --repo via a fork workflow). For merge it is needed only as the FALLBACK
# selector — skipped entirely when the command already carries its own
# explicit target, so a merge run from a detached HEAD or an unrelated cwd
# still triggers as long as it named its target itself.
resolve_branch() {
    [ -n "$CWD" ] || { hook_log "no cwd in the hook payload; skipping"; return 1; }
    cd "$CWD" 2>/dev/null || { hook_log "cwd does not exist: $CWD"; return 1; }
    BRANCH=$(run_timeout "$CI_WATCH_HOOK_TIMEOUT" git branch --show-current 2>/dev/null)
    if [ -z "$BRANCH" ]; then
        hook_log "could not resolve the current branch in $CWD; skipping"
        return 1
    fi
    return 0
}

# --- Step 7: the narrowed per-trigger shape checks. -------------------------
# Each returns non-zero for "out of contract" — which always means skip
# silently, never guess at a target.

# `git push`: bare, or force-only, or exactly `<remote> <currentbranch>`.
# Rejected: `--delete`/`-d`, any `src:dst` refspec (a `:`-prefixed one deletes),
# more than one ref, any other flag, any differing branch.
shape_ok_push() {
    local i t
    local positional=()
    for ((i = 2; i < ${#tokens[@]}; i++)); do
        t="${tokens[$i]}"
        case "$t" in
            -f | --force | --force-with-lease | --force-with-lease=*) ;;
            -*) return 1 ;;
            *) positional+=("$t") ;;
        esac
    done
    case "${#positional[@]}" in
        0) return 0 ;;
        2)
            # A refspec of any kind (including the `:branch` delete form) is
            # not a plain branch name and is therefore out of contract.
            case "${positional[1]}" in *:*) return 1 ;; esac
            [ "${positional[1]}" = "$BRANCH" ] || return 1
            # The remote must be a plain remote NAME, not a URL or a path.
            case "${positional[0]}" in *:* | */*) return 1 ;; esac
            return 0
            ;;
        *) return 1 ;;
    esac
}

# `gh pr create`: no `--head` other than the current branch, no positional
# argument. Flags that only decorate the PR (title, body, labels, draft, ...)
# cannot retarget it, so they stay in contract; their VALUES are stepped over
# so a value never reads as a positional. An explicit `--repo`/`-R` is
# TRUSTED (captured into CREATE_REPO) rather than rejected — the caller named
# the destination repo directly (a fork-workflow `gh pr create --repo
# upstream/repo` still pushes from cwd's own current branch, so BRANCH is
# still the right --head to expect).
CREATE_REPO=""
shape_ok_create() {
    local i t
    for ((i = 3; i < ${#tokens[@]}; i++)); do
        t="${tokens[$i]}"
        case "$t" in
            --repo | -R)
                i=$((i + 1))
                CREATE_REPO="${tokens[$i]:-}"
                [ -n "$CREATE_REPO" ] || return 1
                ;;
            --repo=*)
                CREATE_REPO="${t#--repo=}"
                [ -n "$CREATE_REPO" ] || return 1
                ;;
            --head | -H)
                i=$((i + 1))
                [ "${tokens[$i]:-}" = "$BRANCH" ] || return 1
                ;;
            --head=*) [ "${t#--head=}" = "$BRANCH" ] || return 1 ;;
            -t | --title | -b | --body | -F | --body-file | -B | --base | -a | --assignee | -l | --label | -r | --reviewer | -m | --milestone | -p | --project | -T | --template)
                i=$((i + 1))
                ;;
            -*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# `gh pr merge`: an explicit `--repo`/`-R` is TRUSTED (captured into
# MERGE_REPO) rather than rejected, and AT MOST ONE positional argument — the
# PR number, URL or branch selector `gh pr merge` itself accepts — is TRUSTED
# as the explicit target (captured into MERGE_TARGET) rather than being
# treated as out of contract. The merge command's own success already proves
# `gh` resolved that positional to a real PR, so there is nothing left to
# verify it against the current branch for. A SECOND positional stays out of
# contract: nothing in `gh pr merge`'s grammar takes two, so that shape is
# unrecognized, not a second selector.
MERGE_REPO=""
MERGE_TARGET=""
shape_ok_merge() {
    local i t
    for ((i = 3; i < ${#tokens[@]}; i++)); do
        t="${tokens[$i]}"
        case "$t" in
            --repo | -R)
                i=$((i + 1))
                MERGE_REPO="${tokens[$i]:-}"
                [ -n "$MERGE_REPO" ] || return 1
                ;;
            --repo=*)
                MERGE_REPO="${t#--repo=}"
                [ -n "$MERGE_REPO" ] || return 1
                ;;
            -b | --body | -F | --body-file | -t | --subject | --match-head-commit | --author-email)
                i=$((i + 1))
                ;;
            -*) ;;
            *)
                [ -z "$MERGE_TARGET" ] || return 1
                MERGE_TARGET="$t"
                ;;
        esac
    done
    return 0
}

case "$ACTION" in
    push)
        resolve_branch || exit 0
        shape_ok_push || exit 0
        ;;
    create)
        resolve_branch || exit 0
        shape_ok_create || exit 0
        ;;
    merge)
        shape_ok_merge || exit 0
        if [ -z "$MERGE_TARGET" ]; then
            resolve_branch || exit 0
            MERGE_TARGET="$BRANCH"
        fi
        ;;
esac

# --- Step 8: a push only matters if the branch already has an OPEN PR. ------
# `gh pr create` needs no precheck (the PR was just created, so it is open) and
# neither does `gh pr merge` (the merge command's own success IS the trigger).
if [ "$ACTION" = "push" ]; then
    pr_state=$(run_timeout "$CI_WATCH_HOOK_TIMEOUT" gh pr view "$BRANCH" --json state -q .state 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        hook_log "gh pr view failed (rc=$rc) for $BRANCH; skipping"
        exit 0
    fi
    pr_state=${pr_state//[[:space:]]/}
    [ "$pr_state" = "OPEN" ] || exit 0
fi

# --- Step 9: emit the launch instruction (additionalContext ONLY). ----------
# The opening sentence names what just happened; the rest is identical for all
# three triggers apart from the mode. SELECTOR is what ci_watch.sh's
# second positional gets: the current branch for push/create, or the
# resolved merge target (an explicit PR number/URL/branch, or the current
# branch as fallback) for merge. REPO_FLAG, when non-empty, is an explicit
# --repo this hook was told to trust, forwarded to ci_watch.sh so IT
# also targets that repo instead of resolving one from its own cwd.
case "$ACTION" in
    push)
        SELECTOR="$BRANCH"
        REPO_FLAG=""
        lead="A \`git push\` to '${BRANCH}' with an open PR just succeeded."
        ;;
    create)
        SELECTOR="$BRANCH"
        REPO_FLAG="$CREATE_REPO"
        lead="A \`gh pr create\` for '${BRANCH}' just succeeded, so its PR is open."
        ;;
    merge)
        SELECTOR="$MERGE_TARGET"
        REPO_FLAG="$MERGE_REPO"
        lead="A \`gh pr merge\` of '${MERGE_TARGET}' just succeeded."
        ;;
esac

jq -n \
    --arg lead "$lead" \
    --arg selector "$SELECTOR" \
    --arg kind "$KIND" \
    --arg repo_flag "$REPO_FLAG" \
    '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: (
          $lead
          + " Launch the " + $kind + " watcher: call the Bash tool with "
          + "`command: bash ~/.claude/scripts/ci_watch.sh "
          + $kind + " '"'"'" + $selector + "'"'"'"
          + (if $repo_flag == "" then "" else " --repo '"'"'" + $repo_flag + "'"'"'" end)
          + "` and `run_in_background: true` "
          + "(no explicit `timeout` override — this watcher ends only on a real "
          + "CI result, not a time box). You do not need to check for an "
          + "existing watcher first — the script'"'"'s own lock evicts any "
          + "stale one automatically."
        )
      }
    }'

#!/usr/bin/env bash
#
# PostToolUse:Bash hook — auto-launch the one-shot CI watcher.
#
# After a Bash tool call that (a) really succeeded and (b) matches one of a
# DELIBERATELY NARROW set of command shapes, this hook injects an instruction
# for CLAUDE (never the user) to start skills/ci-watcher/ci_watch_once.sh in
# the background for the branch the command acted on.
#
# The three triggers:
#   1. `git push` of the current branch, when that branch already has an OPEN
#      PR                                          -> push-mode watcher
#   2. `gh pr create` for the current branch       -> push-mode watcher
#   3. `gh pr merge` of the current branch's PR    -> merge-mode watcher
#
# Trigger contract (intentional limitation, documented in the ci-watcher
# skill): a hook cannot reliably parse arbitrary shell. `cd elsewhere && git
# push`, `git -C other push`, a multi-ref push, `gh pr create --repo
# owner/other`, `gh pr merge 123`, a raw GraphQL mutation — none of those can
# be resolved from this hook's own cwd, so NONE of them trigger anything. The
# hook triggers only on the simple forms whose target is unambiguously
# "the current branch of the repo at the hook's cwd", and silently skips
# everything else. `/ci-watcher [branch]` is the manual fallback.
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

# --- Step 4: the two universal gates. ---------------------------------------
# (a) The command must actually have SUCCEEDED. The hook this replaces never
#     checked, so it reproducibly fired on `gh pr merge --help`.
[ "$exit_code" = "0" ] || exit 0

# (b) A help invocation performs no action. The token boundaries matter: a
#     naive substring test would treat `git push origin push-harder` or
#     `git reset -hard` as a help call.
if printf '%s' "$cmd" | grep -qE '(^|[[:space:]])(-h|--help)([[:space:]]|=|$)'; then
    exit 0
fi

# (c) Anything that is not ONE simple command is out of contract: a pipeline, a
#     `&&` chain, a command substitution or a redirect can move the effective
#     repo/branch in ways this hook cannot follow.
# shellcheck disable=SC2016  # `$(` here is a literal two-byte pattern, not an expansion.
case "$cmd" in
    *";"* | *"&"* | *"|"* | *'`'* | *'$('* | *">"* | *"<"* | *$'\n'*) exit 0 ;;
esac

# --- Step 5a: which of the three triggers could this be? --------------------
# Word-split into tokens. Everything that could hide a word boundary (quotes
# aside) was already rejected above.
read -r -a tokens <<<"$cmd"

KIND=""     # the ci_watch_once.sh mode to launch: push | merge
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
[ -n "$CWD" ] || { hook_log "no cwd in the hook payload; skipping"; exit 0; }
cd "$CWD" 2>/dev/null || { hook_log "cwd does not exist: $CWD"; exit 0; }

BRANCH=$(run_timeout "$CI_WATCH_HOOK_TIMEOUT" git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ]; then
    hook_log "could not resolve the current branch in $CWD; skipping"
    exit 0
fi

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

# `gh pr create`: no `--repo`, no `--head` other than the current branch, no
# positional argument. Flags that only decorate the PR (title, body, labels,
# draft, ...) cannot retarget it, so they stay in contract; their VALUES are
# stepped over so a value never reads as a positional.
shape_ok_create() {
    local i t
    for ((i = 3; i < ${#tokens[@]}; i++)); do
        t="${tokens[$i]}"
        case "$t" in
            --repo | -R | --repo=*) return 1 ;;
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

# `gh pr merge`: no `--repo`, and no positional at all — a positional here is
# the PR number, URL or branch selector, i.e. a target this hook did not
# resolve itself.
shape_ok_merge() {
    local i t
    for ((i = 3; i < ${#tokens[@]}; i++)); do
        t="${tokens[$i]}"
        case "$t" in
            --repo | -R | --repo=*) return 1 ;;
            -b | --body | -F | --body-file | -t | --subject | --match-head-commit | --author-email)
                i=$((i + 1))
                ;;
            -*) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

case "$ACTION" in
    push) shape_ok_push || exit 0 ;;
    create) shape_ok_create || exit 0 ;;
    merge) shape_ok_merge || exit 0 ;;
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

# --- Step 9: build the watcher's SLOT the same way the watcher does. --------
# _ci_slug / _ci_watch_key live in scripts/_notify.sh — THE single
# implementation of both recipes, sourced here exactly as ci_watch_once.sh
# sources it, so the paths this message names are byte-for-byte the paths the
# watcher will really create.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=./_notify.sh
source "${SCRIPT_DIR}/_notify.sh" 2>/dev/null || {
    hook_log "could not source _notify.sh"
    exit 0
}

OWNER_REPO=$(run_timeout "$CI_WATCH_HOOK_TIMEOUT" gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)
OWNER_REPO=${OWNER_REPO//[[:space:]]/}
if [ -z "$OWNER_REPO" ]; then
    hook_log "could not resolve owner/repo via gh in $CWD; skipping"
    exit 0
fi

KEY=$(_ci_watch_key "$OWNER_REPO" "$BRANCH" 2>/dev/null) || {
    hook_log "could not compute the watcher key for $OWNER_REPO#$BRANCH; skipping"
    exit 0
}
SLUG=$(_ci_slug "$BRANCH")

# --- Step 10: emit the launch instruction (additionalContext ONLY). ---------
# The opening sentence names what just happened; the rest is identical for all
# three triggers apart from the mode and the task-id filename's kind segment.
case "$ACTION" in
    push) lead="A \`git push\` to '${BRANCH}' with an open PR just succeeded." ;;
    create) lead="A \`gh pr create\` for '${BRANCH}' just succeeded, so its PR is open." ;;
    merge) lead="A \`gh pr merge\` of '${BRANCH}' just succeeded." ;;
esac

# The task_id only exists in the CALLING AGENT's turn, after the Bash tool call
# returns — the watcher script can never know its own external task_id. So the
# agent, not the script, is told to persist it; `/ci-watcher stop-all` reads
# those files later.
jq -n \
    --arg lead "$lead" \
    --arg branch "$BRANCH" \
    --arg kind "$KIND" \
    --arg slug "$SLUG" \
    --arg key "$KEY" \
    '{
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: (
          $lead
          + " Launch the " + $kind + " watcher: call the Bash tool with "
          + "`command: bash ~/.claude/skills/ci-watcher/ci_watch_once.sh "
          + $kind + " '"'"'" + $branch + "'"'"'` and `run_in_background: true` "
          + "(no explicit `timeout` override — this watcher ends only on a real "
          + "CI result, not a time box). Immediately after the call returns its "
          + "`task_id`, write it verbatim (atomic mktemp-in-`/tmp`-then-mv) to "
          + "`/tmp/ci_watch2_task_${CLAUDE_CODE_SESSION_ID}_" + $kind + "_"
          + $slug + "-" + $key + "`. You do not need to check for an existing "
          + "watcher first — the script'"'"'s own lock evicts any stale one "
          + "automatically."
        )
      }
    }'

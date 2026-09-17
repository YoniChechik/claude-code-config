#!/usr/bin/env bash
# permission_request.sh
#
# PermissionRequest hook: auto-allows edits/writes to files under any .claude/
# directory, and bash commands whose every path stays inside .claude/.
#
# Claude Code passes the permission request as JSON on stdin.
# If we decide to allow, we print the allow JSON to stdout.
# If we do not decide (no output), Claude falls through to its normal prompt.
#
# SAFE BY CONSTRUCTION, NOT BY VERB LIST
# --------------------------------------
# The old design sorted verbs into "read" (auto-allow whenever the segment
# mentioned .claude/ anywhere) vs "everything else", and split the command on
# `&&`/`||`/`;` only. Both halves leaked:
#   - a read verb can still write outside: `cat ~/.claude/X > /tmp/out`,
#     `cp ~/.claude/X /tmp/out`, `mv ~/.claude/X /tmp/out`,
#     `tee /tmp/out < ~/.claude/X`, `find ~/.claude -exec rm /tmp/out \;`
#   - not splitting on `|` meant `cat ~/.claude/X | sh` auto-allowed an
#     arbitrary shell
#   - `echo` was "unconditionally safe", so `echo owned > /tmp/out` allowed a
#     write anywhere on disk
#
# The rule is now a whole-command property instead of a per-verb one. A Bash
# command auto-allows ONLY when, across EVERY pipeline segment:
#   1. the command word is on a small allowlist of inspect/manage verbs, and
#   2. EVERY path-looking argument AND every redirection target canonicalizes
#      to somewhere under the resolved .claude directory.
# One argument or redirection target resolving outside .claude, or one verb off
# the allowlist, and the whole command falls through to the normal prompt.
# Falling through is always safe — it just asks the human.

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$CWD" ] || CWD="$HOME"

# The shared library owns path canonicalization (_resolve_path/_resolve_paths/
# _is_under_claude_dir) and the input bounds. Without it nothing below can make
# a safe decision, so exit silently — which means "no auto-allow", i.e. prompt.
# shellcheck source=./_shell_command_guard.sh
if ! source "$(dirname "${BASH_SOURCE[0]}")/_shell_command_guard.sh" 2>/dev/null \
    || ! declare -F _resolve_paths >/dev/null 2>&1; then
    exit 0
fi

allow() {
    printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    exit 0
}

# ---------------------------------------------------------------------------
# Case 1 – File-editing tools: Edit, Write, NotebookEdit
#
# Allow when tool_input.file_path RESOLVES to somewhere under any /.claude/
# directory or is exactly /.claude (e.g. ~/.claude, /some/repo/.claude).
# ---------------------------------------------------------------------------
case "$TOOL_NAME" in
    Edit|Write|NotebookEdit)
        FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
        if [ -n "$FILE_PATH" ]; then
            RESOLVED_FILE_PATH=$(_resolve_path "$CWD" "$FILE_PATH")
            if [ -n "$RESOLVED_FILE_PATH" ] && _is_under_claude_dir "$RESOLVED_FILE_PATH"; then
                allow
            fi
        fi
        exit 0
        ;;
esac

[ "$TOOL_NAME" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$CMD" ] || exit 0

# Oversized/pathological input never auto-allows.
_guard_within_bounds "$CMD" || exit 0

# ---------------------------------------------------------------------------
# Verbs whose behaviour is fully described by their path arguments. Anything
# that runs another program from its arguments (sh, bash, xargs, awk, sed -e
# with commands, ...) is deliberately absent: the path audit below cannot see
# what those would do.
#
# `find` and `cp`/`mv`/`tee` are allowed only because the path audit inspects
# EVERY token, so `find ~/.claude -exec rm /tmp/x \;` and
# `cp ~/.claude/x /tmp/out` are rejected on their outside-.claude token.
# ---------------------------------------------------------------------------
is_allowed_verb() {
    case "$1" in
        echo|cat|ls|head|tail|wc|stat|find|grep|rg|jq|tree|file|diff|\
        mkdir|touch|rm|rmdir|mv|cp|tee|realpath|dirname|basename|du|sort|uniq|cut)
            return 0 ;;
    esac
    return 1
}

# A token is "path-looking" when it could name a filesystem location: it holds
# a `/`, or starts with ~ / $HOME / $CLAUDE_CONFIG_DIR, or is . / .. — never a
# bare word like `-name`, `*.sh` or a grep pattern.
is_path_token() {
    # Anything holding a `/` is covered by the first pattern, including
    # `~/x`, `$HOME/x` and `$CLAUDE_CONFIG_DIR/x`; the rest name a directory
    # on their own. `$tilde` keeps the tilde unmistakably literal.
    local tilde='~'
    case "$1" in
        */*|"$tilde"|.|..) return 0 ;;
        '$HOME'|'${HOME}'|'$CLAUDE_CONFIG_DIR') return 0 ;;
    esac
    return 1
}

# Collect every path that must be proven to live under .claude/. Populates the
# PATHS array and returns 1 when the command must not auto-allow at all
# (unknown verb, an unexpandable variable, a nested shell, ...).
PATHS=()
SAW_CLAUDE_CANDIDATE=0

collect_segment_paths() { # <segment>
    local seg="$1"
    local -a toks=()
    local tok next verb=""
    local expect_redirect=0
    local i n

    # Word-split with globbing OFF: an unquoted expansion here would otherwise
    # let a `*` in the command hit the real filesystem.
    set -f
    read -r -a toks <<<"$seg"
    set +f
    n=${#toks[@]}
    [ "$n" -gt 0 ] || return 0

    i=0
    while [ "$i" -lt "$n" ]; do
        tok="${toks[$i]}"
        # Strip quote characters; they change nothing about which path is named.
        tok="${tok//\"/}"
        tok="${tok//\'/}"
        i=$((i + 1))
        [ -n "$tok" ] || continue

        if [ "$expect_redirect" = "1" ]; then
            expect_redirect=0
            PATHS+=("$tok")
            continue
        fi

        # Redirections, glued (`>/tmp/x`, `2>>log`) or separated (`> /tmp/x`).
        # `<<WORD` is a heredoc delimiter, not a path, and `<<<` is a here-string
        # whose operand is data — both are only checked when they LOOK like a path.
        if [[ "$tok" =~ ^[0-9]*([&]?[>][>]?|[>][&]|[<][<][<]|[<])(.*)$ ]]; then
            next="${BASH_REMATCH[2]}"
            if [ -z "$next" ]; then
                expect_redirect=1
            else
                PATHS+=("$next")
            fi
            continue
        fi
        case "$tok" in
            '<<'*) continue ;;
        esac

        # An unexpandable expansion or a nested command substitution makes the
        # command opaque — never auto-allow it.
        case "$tok" in
            *'$('*|*'`'*) return 1 ;;
            '$'*)
                case "$tok" in
                    '$HOME'|'$HOME/'*|'${HOME}'|'${HOME}/'*|'$CLAUDE_CONFIG_DIR'|'$CLAUDE_CONFIG_DIR/'*) ;;
                    *) return 1 ;;
                esac
                ;;
        esac

        if [ -z "$verb" ]; then
            verb="${tok##*/}"
            is_allowed_verb "$verb" || return 1
            continue
        fi

        # `--output=/tmp/x` style: the path is the flag's value.
        case "$tok" in
            --[A-Za-z0-9]*=*)
                next="${tok#*=}"
                is_path_token "$next" && PATHS+=("$next")
                continue
                ;;
            -*)
                # A plain flag names no path.
                is_path_token "$tok" || continue
                ;;
        esac

        if is_path_token "$tok"; then
            PATHS+=("$tok")
        fi
    done
    return 0
}

# Split on every separator that starts a new command, `|` included. Not
# splitting on `|` is what let `cat ~/.claude/X | sh` auto-allow a shell.
SPLIT="${CMD//;/$'\n'}"
SPLIT="${SPLIT//&/$'\n'}"
SPLIT="${SPLIT//|/$'\n'}"

SAW_SEGMENT=0
while IFS= read -r SEG; do
    SEG="${SEG#"${SEG%%[![:space:]]*}"}"
    SEG="${SEG%"${SEG##*[![:space:]]}"}"
    [ -z "$SEG" ] && continue
    # Shell grammar (`{`, `if`, `then`, subshell parens, `VAR=`, `command`, …)
    # has no business in an auto-allowed command; peel it and require what is
    # left to still be an allowlisted verb.
    _strip_leading_wrappers "$SEG"
    SEG="$GUARD_REPLY"
    [ -z "$SEG" ] && continue
    SAW_SEGMENT=1
    collect_segment_paths "$SEG" || exit 0
done <<<"$SPLIT"

[ "$SAW_SEGMENT" = "1" ] || exit 0

# ---------------------------------------------------------------------------
# One python3 fork canonicalizes every collected path at once, then EVERY one
# of them must land under .claude. A single outside path (argument OR
# redirection target) means no auto-allow.
# ---------------------------------------------------------------------------
if [ "${#PATHS[@]}" -gt 0 ]; then
    RESOLVED_COUNT=0
    while IFS= read -r RESOLVED; do
        [ -n "$RESOLVED" ] || exit 0
        _is_under_claude_dir "$RESOLVED" || exit 0
        RESOLVED_COUNT=$((RESOLVED_COUNT + 1))
        SAW_CLAUDE_CANDIDATE=1
    done < <(_resolve_paths "$CWD" "${PATHS[@]}")
    # Every collected path must have come back resolved. A short answer means
    # the resolver failed partway, which proves nothing about the missing ones.
    [ "$RESOLVED_COUNT" = "${#PATHS[@]}" ] || exit 0
fi

# Require the command to actually be ABOUT .claude: a command with no path at
# all (`echo hi`) is not this hook's business, so it falls through and Claude
# applies its normal rules.
[ "$SAW_CLAUDE_CANDIDATE" = "1" ] || exit 0

allow

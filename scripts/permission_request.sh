#!/usr/bin/env bash
# permission_request.sh
#
# PermissionRequest hook: auto-allows edits/writes to files under any .claude/
# directory and bash commands whose every segment operates inside .claude/.
#
# Claude Code passes the permission request as JSON on stdin.
# If we decide to allow, we print the allow JSON to stdout.
# If we do not decide (no output), Claude falls through to its normal prompt.

# ---------------------------------------------------------------------------
# Read and parse the incoming JSON payload from stdin
# ---------------------------------------------------------------------------
INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
[ -n "$CWD" ] || CWD="$HOME"

# ---------------------------------------------------------------------------
# Helper: emit the allow decision and exit successfully
# ---------------------------------------------------------------------------
allow() {
    printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    exit 0
}

# ---------------------------------------------------------------------------
# Helper: canonicalize a path (resolving `..`/`.`/symlinks) before it is ever
# pattern-matched against ".claude". Matching the RAW, unresolved text (as
# this file used to) is a path-traversal bypass: `.../.claude/../../etc/hosts`
# contains the substring "/.claude/" while actually pointing well outside it.
# `~`/`$HOME`/`$CLAUDE_CONFIG_DIR` are expanded textually first, since the
# hook only ever sees the command/path as literal text, never a real shell's
# expansion of it.
#
# Uses python3's os.path.realpath rather than the platform `realpath`/
# `readlink -f`: BSD realpath (macOS) refuses to resolve a path unless EVERY
# component already exists on disk, which breaks the common case of a Write
# to a file that doesn't exist yet. os.path.realpath resolves symlinks where
# it can and lexically normalizes the rest, existing or not.
_resolve_path() {
    local base="$1" token="$2"
    local claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    token="${token/#\~/$HOME}"
    token="${token/#\$HOME/$HOME}"
    token="${token/#\$CLAUDE_CONFIG_DIR/$claude_dir}"
    python3 -c '
import os, sys
base, p = sys.argv[1], sys.argv[2]
if not os.path.isabs(p):
    p = os.path.join(base, p)
print(os.path.realpath(p))
' "$base" "$token" 2>/dev/null
}

# Helper: is RESOLVED (already-canonicalized, per _resolve_path) a path under
# a directory literally named `.claude`? Safe to substring-match here BECAUSE
# the path has already had every `.`/`..`/symlink collapsed — there is no
# traversal token left for a lookalike to hide behind.
_is_under_claude_dir() {
    case "$1" in
        */.claude/*|*/.claude) return 0 ;;
        *) return 1 ;;
    esac
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
            if _is_under_claude_dir "$RESOLVED_FILE_PATH"; then
                allow
            fi
        fi
        ;;
esac

# ---------------------------------------------------------------------------
# Case 2 – Bash commands
#
# Split the command on &&, ||, and ; to get individual segments, then verify
# that EVERY non-empty segment is either:
#   • an unconditionally safe verb (echo) with no path concerns, OR
#   • a destructive-ish verb (rm, rmdir) whose every path token is in .claude/, OR
#   • a read/inspect verb (cat, ls, head, …) that references .claude/ somewhere
#     in the segment.
#
# If all segments pass → allow. If any segment fails → do nothing (fall through).
# ---------------------------------------------------------------------------
if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

    # Split on && || ; into one segment per line
    SEGS=$(printf '%s' "$CMD" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g')

    # Track whether we have seen any non-empty segment and whether all pass
    ALL=1   # assume all segments are OK until proven otherwise
    ANY=0   # becomes 1 once we see at least one non-empty segment

    while IFS= read -r SEG; do
        # Strip leading/trailing whitespace
        SEG=$(printf '%s' "$SEG" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -z "$SEG" ] && continue   # skip blank lines produced by the split

        ANY=1
        VERB=$(printf '%s' "$SEG" | awk '{print $1}')

        case "$VERB" in
            # ----------------------------------------------------------------
            # Unconditionally safe: echo never touches files
            # ----------------------------------------------------------------
            echo)
                : # OK — no path check needed
                ;;

            # ----------------------------------------------------------------
            # Destructive verbs: every explicit path argument must be in .claude/
            # ----------------------------------------------------------------
            rm|rmdir)
                REST=$(printf '%s' "$SEG" | awk '{$1=""; print substr($0,2)}')
                SALL=1   # all path tokens for this segment resolve inside .claude/
                SANY=0   # at least one path token seen

                for TOK in $REST; do
                    # Skip flag tokens like -rf, --recursive, etc.
                    case "$TOK" in -*) continue ;; esac
                    SANY=1
                    RESOLVED_TOK=$(_resolve_path "$CWD" "$TOK")
                    if ! _is_under_claude_dir "$RESOLVED_TOK"; then
                        SALL=0
                        break
                    fi
                done

                # Reject if no path tokens were found OR any token resolved outside .claude/
                if [ "$SANY" != 1 ] || [ "$SALL" != 1 ]; then
                    ALL=0
                    break
                fi
                ;;

            # ----------------------------------------------------------------
            # Read/inspect/navigate verbs: at least one non-flag token in the
            # segment must RESOLVE to somewhere under .claude/ (covers quoted
            # and ~/$HOME/$CLAUDE_CONFIG_DIR-prefixed paths, textually
            # expanded by _resolve_path before canonicalization).
            # ----------------------------------------------------------------
            cat|ls|head|tail|wc|stat|find|grep|rg|jq|tree|file|mkdir|touch|mv|cp|tee)
                REST=$(printf '%s' "$SEG" | awk '{$1=""; print substr($0,2)}')
                SEG_HAS_CLAUDE_TOKEN=0
                for TOK in $REST; do
                    case "$TOK" in -*) continue ;; esac
                    RESOLVED_TOK=$(_resolve_path "$CWD" "$TOK")
                    if _is_under_claude_dir "$RESOLVED_TOK"; then
                        SEG_HAS_CLAUDE_TOKEN=1
                        break
                    fi
                done
                if [ "$SEG_HAS_CLAUDE_TOKEN" != 1 ]; then
                    ALL=0
                    break
                fi
                ;;

            # ----------------------------------------------------------------
            # Any other verb is not on our allowlist → do not auto-allow
            # ----------------------------------------------------------------
            *)
                ALL=0
                break
                ;;
        esac
    done <<EOF
$SEGS
EOF

    # Allow only when we saw segments and every one of them passed
    if [ "$ANY" = 1 ] && [ "$ALL" = 1 ]; then
        allow
    fi
fi

# ---------------------------------------------------------------------------
# Neither condition matched → exit 0 with no output so Claude prompts normally
# ---------------------------------------------------------------------------
exit 0

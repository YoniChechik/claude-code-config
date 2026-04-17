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

# ---------------------------------------------------------------------------
# Helper: emit the allow decision and exit successfully
# ---------------------------------------------------------------------------
allow() {
    printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    exit 0
}

# ---------------------------------------------------------------------------
# Case 1 – File-editing tools: Edit, Write, NotebookEdit
#
# Allow when tool_input.file_path is under any /.claude/ directory or is
# exactly /.claude (e.g. ~/.claude, /some/repo/.claude).
# ---------------------------------------------------------------------------
case "$TOOL_NAME" in
    Edit|Write|NotebookEdit)
        FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')
        case "$FILE_PATH" in
            # Matches paths like /home/user/.claude/foo or /home/user/.claude
            */.claude/*|*/.claude)
                allow
                ;;
        esac
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
                SALL=1   # all path tokens for this segment are in .claude/
                SANY=0   # at least one path token seen

                for TOK in $REST; do
                    # Skip flag tokens like -rf, --recursive, etc.
                    case "$TOK" in -*) continue ;; esac
                    SANY=1
                    case "$TOK" in
                        */.claude/*|*/.claude|~/.claude*|'$HOME/.claude'*|'$CLAUDE_CONFIG_DIR'*)
                            : # OK
                            ;;
                        *)
                            SALL=0
                            break
                            ;;
                    esac
                done

                # Reject if no path tokens were found OR any token was outside .claude/
                if [ "$SANY" != 1 ] || [ "$SALL" != 1 ]; then
                    ALL=0
                    break
                fi
                ;;

            # ----------------------------------------------------------------
            # Read/inspect/navigate verbs: the segment must reference .claude/
            # somewhere (covers quoted and variable-expanded paths)
            # ----------------------------------------------------------------
            cat|ls|head|tail|wc|stat|find|grep|rg|jq|tree|file|mkdir|touch|mv|cp|tee)
                if ! printf '%s' "$SEG" | grep -qE '(/\.claude(/|$|[[:space:]])|~/\.claude|\$HOME/\.claude|\$CLAUDE_CONFIG_DIR)'; then
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

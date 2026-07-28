#!/usr/bin/env bash
#
# PostToolUse hook: clears a GREEN tab once Claude is demonstrably working again.
#
# GREEN means "Claude is blocked on YOU". Every painter of it (Stop, Notification,
# the AskUserQuestion ping, the Bash permission-guard's `ask`) is a one-way
# transition — before this hook the only way back was UserPromptSubmit. A session
# that keeps working without a new user prompt (permission approved, question
# answered, agents orchestrated) therefore stayed green for hours while work was
# in progress, which is exactly the false "waiting for you" signal reported.
#
# A completed tool call is the unambiguous proof that Claude is no longer blocked:
# whatever the user had to do, they did it.

# --- Step 1: only ever act on a tab WE last painted green.
# Blue (background work in progress) and an unpainted tab must be left alone —
# a background agent's own tool calls would otherwise erase the blue bar that
# says it is still running. This also keeps the common path to a single file
# read: no state recorded means no work to do.
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

INPUT=$(cat)

[ "$(tab_state)" = "green" ] || exit 0

# --- Step 2: never wipe a DELIBERATE ping.
# The notify-waiting skill paints green immediately before Claude blocks on a
# manual action, so the ping's own tool call completing does NOT mean the user
# has acted — the waiting has not even started. Matching on the tool INPUT only
# (never the response) keeps a tool that merely read this repo's notify code from
# being mistaken for the ping itself.
TOOL_INPUT=$(printf '%s' "$INPUT" | jq -c '.tool_input // empty' 2>/dev/null)
case "$TOOL_INPUT" in
    *notify_user_attention*|*notify-waiting*) exit 0 ;;
esac

# --- Step 3: back to the default tab colour. The next Stop repaints green (or
# blue) from scratch, so nothing is lost by clearing rather than re-deciding
# here — and re-deciding would cost a full transcript scan on every tool call.
reset_tab_color

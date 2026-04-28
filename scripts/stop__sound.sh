#!/usr/bin/env bash

source "$(dirname "${BASH_SOURCE[0]}")/notify_waiting.sh"

# Read the Stop hook JSON payload from stdin
INPUT=$(cat)

# Extract the transcript path from the hook payload
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

# If we have a transcript, check for active background agents.
# Fall through to notify_waiting on any parse error.
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    ACTIVE_COUNT=$(python3 - "$TRANSCRIPT_PATH" <<'PYEOF'
import sys, json, re, os

transcript_path = sys.argv[1]
debug = os.environ.get("CLAUDE_DEBUG_STOP") == "1"

# Any of these statuses in a <task-notification> means the agent is no longer
# running. Treating only "completed" as terminal would leave failed/cancelled
# agents pinned as "active" forever and silence the stop sound permanently.
TERMINAL_STATUSES = {
    "completed", "failed", "cancelled", "canceled",
    "error", "errored", "timeout", "timed_out", "aborted",
}

# agent IDs that were async-launched (toolUseResult.agentId)
launched = set()
# task-ids that reached a terminal status (parsed from <task-notification> blocks).
# These are the SAME identifier namespace as agentId — both sides use the
# 17-char "a"-prefixed hex string, so direct set subtraction works.
terminated = set()

# Match <task-notification> blocks and pull out their <task-id> + <status>.
# DOTALL so .*? crosses the literal "\n" inside the JSON-encoded string.
TASK_NOTIF_RE = re.compile(
    r"<task-notification>(.*?)</task-notification>", re.DOTALL
)
TASK_ID_RE = re.compile(r"<task-id>\s*([^<\s]+)\s*</task-id>")
STATUS_RE = re.compile(r"<status>\s*([^<\s]+)\s*</status>")

def scan_text_for_terminations(text):
    if not text or "<task-notification>" not in text:
        return
    for block in TASK_NOTIF_RE.findall(text):
        status_match = STATUS_RE.search(block)
        if not status_match:
            continue
        status = status_match.group(1).strip().lower()
        if status not in TERMINAL_STATUSES:
            continue
        task_id_match = TASK_ID_RE.search(block)
        if task_id_match:
            terminated.add(task_id_match.group(1).strip())

try:
    with open(transcript_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            # --- Launches: toolUseResult.status == "async_launched" carries agentId
            tool_result = entry.get("toolUseResult", {})
            if isinstance(tool_result, dict) and tool_result.get("status") == "async_launched":
                agent_id = tool_result.get("agentId") or entry.get("agentId")
                if agent_id:
                    launched.add(agent_id)

            # --- Terminations: <task-notification> blocks appear in multiple forms.
            # Form 1: queue-operation entry, top-level "content" is a plain string
            top_content = entry.get("content")
            if isinstance(top_content, str):
                scan_text_for_terminations(top_content)

            # Form 2: user/assistant message.content as plain string or block list
            message = entry.get("message", {})
            if isinstance(message, dict):
                content = message.get("content")
                if isinstance(content, str):
                    scan_text_for_terminations(content)
                elif isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        text = block.get("text", "") or ""
                        scan_text_for_terminations(text)

    # Active = launched agents whose ID we haven't seen reach a terminal status
    active = launched - terminated
    if debug:
        print(
            f"[stop__sound] launched={sorted(launched)} "
            f"terminated={sorted(terminated)} active={sorted(active)}",
            file=sys.stderr,
        )
    print(len(active))
except Exception as e:
    if debug:
        print(f"[stop__sound] error: {e!r}", file=sys.stderr)
    # On any error, assume 0 active so sound plays
    print(0)
PYEOF
    2>/dev/null)

    # If active agent count > 0, suppress the sound and exit silently
    if [ -n "$ACTIVE_COUNT" ] && [ "$ACTIVE_COUNT" -gt 0 ] 2>/dev/null; then
        exit 0
    fi
fi

# Turn iTerm2 tab green — Claude is now idle/waiting for user or subagent
printf '\033]6;1;bg;red;brightness;0\a\033]6;1;bg;green;brightness;180\a\033]6;1;bg;blue;brightness;0\a' > /dev/tty 2>/dev/null || true

# Clear the iTerm2 tab badge — the stop__title.sh hook will set it to
# "✅ Done (OrgName)" right after us, but if this hook runs without that
# one (e.g. suppressed by active agents above) we still want a clean slate.
# Passing an empty base64 payload clears any previously set badge text.
printf '\e]1337;SetBadgeFormat=\a' > /dev/tty 2>/dev/null || true

notify_waiting

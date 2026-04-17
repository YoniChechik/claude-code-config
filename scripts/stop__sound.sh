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
import sys, json

transcript_path = sys.argv[1]

# Collect all agent IDs that were async-launched
launched = set()
# Collect all task-ids that completed (from <status>completed</status> messages)
completed = set()

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

            # Detect async_launched tool-use results
            tool_result = entry.get("toolUseResult", {})
            if isinstance(tool_result, dict) and tool_result.get("status") == "async_launched":
                agent_id = tool_result.get("agentId") or entry.get("agentId")
                if agent_id:
                    launched.add(agent_id)

            # Detect completed background agents by scanning message content
            # for <status>completed</status> blocks which contain <task-id>...</task-id>
            message = entry.get("message", {})
            if isinstance(message, dict):
                content = message.get("content", [])
                if isinstance(content, list):
                    for block in content:
                        if not isinstance(block, dict):
                            continue
                        text = block.get("text", "") or ""
                        if "<status>completed</status>" in text:
                            # Extract all <task-id>VALUE</task-id> occurrences
                            import re
                            for task_id in re.findall(r"<task-id>(.*?)</task-id>", text):
                                completed.add(task_id.strip())

    # Active = launched agents whose ID is not in the completed set
    active = launched - completed
    print(len(active))
except Exception:
    # On any error, assume 0 active so sound plays
    print(0)
PYEOF
    2>/dev/null)

    # If active agent count > 0, suppress the sound and exit silently
    if [ -n "$ACTIVE_COUNT" ] && [ "$ACTIVE_COUNT" -gt 0 ] 2>/dev/null; then
        exit 0
    fi
fi

notify_waiting

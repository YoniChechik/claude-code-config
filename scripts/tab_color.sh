#!/usr/bin/env bash

set -uo pipefail

input=$(cat)

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/_notify.sh"

event="" session="" agent="" ntype="" crons="" tasks=""
IFS=$'\x1f' read -r event session agent ntype crons tasks < <(
    jq -r '[
        (.hook_event_name // ""),
        (.session_id // ""),
        (.agent_id // "main"),
        (.notification_type // ""),
        (.session_crons | if type == "array" then (length | tostring) else "unknown" end),
        (.background_tasks | if type == "array" then (length | tostring) else "unknown" end)
    ] | join("\u001f")' <<< "$input" 2>/dev/null
)
agent=${agent:-main}

pending=""
[ -n "$session" ] && pending="${CLAUDE_NOTIFY_TMP_DIR}/tab_pending_${session}"

blocked_by_other_agent() {
    [ -n "$pending" ] && [ -f "$pending" ] || return 1
    local owner
    owner=$(head -c 256 "$pending" 2>/dev/null)
    [ -n "$owner" ] && [ "$owner" != "$agent" ]
}

clear_pending() {
    [ -z "$pending" ] || rm -f "$pending"
}

await_human() {
    [ -z "$pending" ] || printf '%s' "$agent" > "$pending"
    set_tab_pink
}

is_positive() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

case "$event" in
    SessionStart)
        clear_pending
        set_tab_pink
        ;;
    SessionEnd)
        clear_pending
        reset_tab_color
        ;;
    PreToolUse | PermissionRequest | Elicitation)
        await_human
        ;;
    Notification)
        case "$ntype" in
            permission_prompt | worker_permission_prompt | elicitation_dialog | elicitation_url_dialog | agent_needs_input | quota_auto_resume_stale)
                set_tab_pink
                ;;
        esac
        ;;
    UserPromptSubmit | PostToolUse | PostToolUseFailure | ElicitationResult | SubagentStop)
        blocked_by_other_agent && exit 0
        clear_pending
        set_tab_blue
        ;;
    Stop)
        blocked_by_other_agent && exit 0
        clear_pending
        if [ "$crons" = 0 ] && [ "$tasks" = 0 ]; then
            set_tab_pink
        else
            set_tab_blue
        fi
        ;;
    StopFailure)
        blocked_by_other_agent && exit 0
        clear_pending
        if is_positive "$crons" || is_positive "$tasks"; then
            set_tab_blue
        else
            set_tab_pink
        fi
        ;;
esac

exit 0

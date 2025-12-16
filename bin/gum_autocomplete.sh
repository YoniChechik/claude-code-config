#!/bin/bash
# gum_autocomplete.sh - Gum-based autocomplete for cc command

# Get list of available slash commands
get_slash_commands() {
    local cmds=()
    for f in "$CLAUDE_DIR"/commands/*.md; do
        [[ -f "$f" ]] && cmds+=("$(basename "$f" .md)")
    done
    printf '%s\n' "${cmds[@]}" | sort
}

# Run autocomplete with gum filter, return selected command or empty
# Sets AUTOCOMPLETE_RESULT
run_autocomplete_gum() {
    local commands
    commands=$(get_slash_commands)

    # Handle empty command list
    if [[ -z "$commands" ]]; then
        AUTOCOMPLETE_RESULT=""
        return 1
    fi

    # Run gum filter
    local result
    result=$(echo "$commands" | gum filter \
        --placeholder="Search commands..." \
        --height=10 \
        --no-limit=false \
        2>/dev/null)

    local exit_code=$?

    # Check exit code
    # 0 = selection made
    # 1 = error/cancelled
    # 130 = Ctrl+C
    if [[ $exit_code -eq 0 && -n "$result" ]]; then
        # Clear the line before printing result
        printf '\r\033[K> /%s\n' "$result"
        AUTOCOMPLETE_RESULT="/$result"
        return 0
    elif [[ $exit_code -eq 130 ]]; then
        # Ctrl+C - clear and cancel
        printf '\r\033[K'
        AUTOCOMPLETE_RESULT=""
        return 1
    else
        # Cancelled or error
        printf '\r\033[K'
        AUTOCOMPLETE_RESULT=""
        return 1
    fi
}

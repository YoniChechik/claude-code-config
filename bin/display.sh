#!/bin/bash
# display.sh - Display functions using gum for consistent styling

# Yellow prompt text
display_prompt() {
    gum style --foreground="yellow" "$1"
}

# Red error text
display_error() {
    gum style --foreground="red" "$1"
}

# Yellow warning text
display_warning() {
    gum style --foreground="yellow" "$1"
}

# Green success text
display_success() {
    gum style --foreground="green" "$1"
}

# Gray info text
display_info() {
    gum style --foreground="240" "$1"
}

# Rounded border banner with padding
display_banner() {
    gum style --border="rounded" --padding="0 1" "$1"
}

# Gray subagent prefix
display_subagent_prefix() {
    gum style --foreground="240" --inline "|"
}

# Gray stopped message
display_stopped() {
    echo ""
    gum style --foreground="240" "[Stopped]"
}

# Yellow timeout message
display_timeout() {
    echo ""
    gum style --foreground="yellow" "Timeout: No response for 30s. Sending 'continue'..."
    echo ""
}

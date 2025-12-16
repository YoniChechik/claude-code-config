#!/bin/bash

# Demo script showing the interactive autocomplete UI using gum
# Demonstrates gum filter vertical dropdown for slash commands

CLAUDE_DIR="$HOME/.claude"

# Source display functions
source "$CLAUDE_DIR/bin/display.sh"

# =============================================================================
# AUTOCOMPLETE FUNCTIONS (from bin/gum_autocomplete.sh)
# =============================================================================

# Get list of available slash commands
get_slash_commands() {
    local cmds=()
    for f in "$CLAUDE_DIR"/commands/*.md; do
        [[ -f "$f" ]] && cmds+=("$(basename "$f" .md)")
    done
    printf '%s\n' "${cmds[@]}" | sort
}

# =============================================================================
# DEMO UTILITIES
# =============================================================================

demo_header() {
    echo ""
    gum style --border="double" --padding="0 2" --foreground="cyan" "$1"
    echo ""
}

scenario_header() {
    gum style --foreground="yellow" --bold ">> $1"
    echo ""
}

info_text() {
    gum style --foreground="240" "$1"
}

show_prompt() {
    echo -n "> "
}

# Render a simulated gum filter dropdown
render_demo_filter() {
    local -n items=$1
    local query=$2
    local selected=${3:-0}
    local max_show=5

    local count=${#items[@]}
    [[ $count -eq 0 ]] && return

    local show=$((count < max_show ? count : max_show))

    # Show filter header
    gum style --foreground="240" "  Search commands..."

    # Show items vertically like gum filter
    for ((i=0; i<show; i++)); do
        local prefix="  "
        if [[ $i -eq $selected ]]; then
            gum style --foreground="212" --bold "$prefix> /${items[$i]}"
        else
            gum style --foreground="240" "$prefix  /${items[$i]}"
        fi
    done

    if [[ $count -gt $max_show ]]; then
        gum style --foreground="240" "  ... and $((count - max_show)) more"
    fi
}

# =============================================================================
# SCENARIO 1: User types "/" - Show all commands
# =============================================================================
demo_scenario_1() {
    scenario_header "User types '/' - Gum filter opens"

    info_text "When user types '/', the gum filter dropdown appears showing"
    info_text "all available commands in a vertical list."
    echo ""

    show_prompt
    echo "/"
    echo ""

    # Get all commands
    local -a all_cmds
    mapfile -t all_cmds < <(get_slash_commands)

    render_demo_filter all_cmds "" 0
    echo ""
}

# =============================================================================
# SCENARIO 2: User types "pr" - Filtering in progress
# =============================================================================
demo_scenario_2() {
    scenario_header "User types 'pr' - Filtered results"

    info_text "As the user types, gum filter narrows down to matching commands."
    info_text "The filter is fuzzy - it matches anywhere in the command name."
    echo ""

    show_prompt
    echo "/pr"
    echo ""

    # Get all commands and filter
    local -a all_cmds
    mapfile -t all_cmds < <(get_slash_commands)

    local -a filtered
    for cmd in "${all_cmds[@]}"; do
        [[ "$cmd" == *pr* ]] && filtered+=("$cmd")
    done

    render_demo_filter filtered "pr" 0
    echo ""
}

# =============================================================================
# SCENARIO 3: User navigates with arrow keys
# =============================================================================
demo_scenario_3() {
    scenario_header "User presses down arrow - Selection moves"

    info_text "Arrow keys move the selection highlight up and down."
    info_text "The selected item is shown in magenta with a '>' indicator."
    echo ""

    show_prompt
    echo "/sy"
    echo ""

    # Get all commands and filter for /sy
    local -a all_cmds
    mapfile -t all_cmds < <(get_slash_commands)

    local -a filtered
    for cmd in "${all_cmds[@]}"; do
        [[ "$cmd" == *sy* ]] && filtered+=("$cmd")
    done

    gum style --foreground="240" "Initial selection (first item):"
    render_demo_filter filtered "sy" 0
    echo ""

    gum style --foreground="240" "After Down arrow press (second item):"
    render_demo_filter filtered "sy" 1
    echo ""
}

# =============================================================================
# SCENARIO 4: User selects a command with Enter
# =============================================================================
demo_scenario_4() {
    scenario_header "User presses Enter - Command selected"

    info_text "After selecting a command with Enter, the filter closes"
    info_text "and the selected command is submitted to Claude."
    echo ""

    show_prompt
    echo "/sync"
    echo ""

    display_success "  Selected: /sync"
    echo ""

    info_text "The command is now sent to Claude for processing..."
    echo ""
}

# =============================================================================
# SCENARIO 5: Empty filter results
# =============================================================================
demo_scenario_5() {
    scenario_header "User types non-matching text - No results"

    info_text "When the filter query doesn't match any commands,"
    info_text "an empty list is shown. User can backspace to try again."
    echo ""

    show_prompt
    echo "/xyz"
    echo ""

    gum style --foreground="240" "  Search commands..."
    gum style --foreground="240" --italic "  (no matches)"
    echo ""
}

# =============================================================================
# SCENARIO 6: Key Bindings Reference
# =============================================================================
demo_scenario_6() {
    scenario_header "Key Bindings Reference"

    gum style --foreground="cyan" --bold "Navigation:"
    gum style --foreground="white" "  Up/Down arrows  - Move selection"
    gum style --foreground="white" "  Type characters - Filter commands"
    gum style --foreground="white" "  Backspace       - Delete last character"
    echo ""

    gum style --foreground="cyan" --bold "Selection:"
    gum style --foreground="white" "  Enter           - Submit selected command"
    gum style --foreground="white" "  Escape / Ctrl+C - Cancel autocomplete"
    gum style --foreground="white" "  Ctrl+D          - Exit the REPL"
    echo ""
}

# =============================================================================
# MAIN DEMO
# =============================================================================

main() {
    demo_header "Interactive Slash Command Autocomplete Demo"

    gum style --foreground="white" "This demo shows how the gum-based autocomplete interface works."
    gum style --foreground="white" "Commands appear in a vertical dropdown list. Use arrow keys to navigate."
    echo ""

    # Run all scenarios
    demo_scenario_1
    sleep 1

    demo_scenario_2
    sleep 1

    demo_scenario_3
    sleep 1

    demo_scenario_4
    sleep 1

    demo_scenario_5
    sleep 1

    demo_scenario_6

    echo ""
    demo_header "Demo Complete"

    gum style --foreground="white" "To use the actual autocomplete, start the REPL with:"
    echo ""
    gum style --foreground="cyan" --bold "  cc"
    echo ""
    gum style --foreground="white" "Then type '/' to see the live gum filter menu."
    echo ""
}

main "$@"

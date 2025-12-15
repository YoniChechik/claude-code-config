#!/bin/bash

# Demo script showing the interactive autocomplete UI
# Replicates autocomplete functions and simulates various scenarios

CLAUDE_DIR="$HOME/.claude"

# Colors and formatting
HEADER_COLOR='\033[1;36m'  # Bright cyan
SCENARIO_COLOR='\033[1;33m' # Bright yellow
SUBHEADER_COLOR='\033[1;34m' # Bright blue
INFO_COLOR='\033[90m'       # Gray
RESET='\033[0m'

# =============================================================================
# AUTOCOMPLETE FUNCTIONS (from bin/cc)
# =============================================================================

# Get list of available slash commands
get_slash_commands() {
    local cmds=()
    for f in "$CLAUDE_DIR"/commands/*.md; do
        [[ -f "$f" ]] && cmds+=("$(basename "$f" .md)")
    done
    printf '%s\n' "${cmds[@]}" | sort
}

# Filter commands by prefix
filter_commands() {
    local prefix="$1"
    local cmd
    while IFS= read -r cmd; do
        [[ "$cmd" == "$prefix"* ]] && echo "$cmd"
    done
}

# =============================================================================
# DEMO UTILITIES
# =============================================================================

demo_header() {
    echo
    echo -e "${HEADER_COLOR}═══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${HEADER_COLOR}$1${RESET}"
    echo -e "${HEADER_COLOR}═══════════════════════════════════════════════════════════════${RESET}"
    echo
}

scenario_header() {
    echo -e "${SCENARIO_COLOR}▶ $1${RESET}"
    echo
}

info_text() {
    echo -e "${INFO_COLOR}$1${RESET}"
}

show_prompt() {
    echo -n "> "
}

# Simulate rendering a menu state with ANSI codes (static display, no animation)
render_demo_menu() {
    local -n items=$1
    local selected=$2
    local max_show=10

    local count=${#items[@]}
    [[ $count -eq 0 ]] && return

    local show=$((count < max_show ? count : max_show))

    # Show filtered items with selection highlight
    for ((i=0; i<show; i++)); do
        if [[ $i -eq $selected ]]; then
            printf '    \033[7m /%s \033[0m\n' "${items[$i]}"
        else
            printf '    /%s\n' "${items[$i]}"
        fi
    done
}

# =============================================================================
# SCENARIO 1: User types "/" - Show all commands
# =============================================================================
demo_scenario_1() {
    scenario_header "User types '/' - All commands appear"

    info_text "When user types the first character '/', the autocomplete menu opens and"
    info_text "shows all available commands sorted alphabetically."
    echo

    show_prompt
    echo "/"
    echo

    # Get all commands
    local -a all_cmds
    mapfile -t all_cmds < <(get_slash_commands)

    render_demo_menu all_cmds 0
    echo
}

# =============================================================================
# SCENARIO 2: User types "/pr" - Filtering in progress
# =============================================================================
demo_scenario_2() {
    scenario_header "User types '/pr' - Filtered to matching commands"

    info_text "As the user types 'p' then 'r', the menu filters to only commands"
    info_text "starting with '/pr'. The selection automatically resets to the first item."
    echo

    show_prompt
    echo "/pr"
    echo

    # Get all commands and filter
    local -a all_cmds
    mapfile -t all_cmds < <(get_slash_commands)

    local -a filtered
    mapfile -t filtered < <(printf '%s\n' "${all_cmds[@]}" | filter_commands "pr")

    render_demo_menu filtered 0
    echo
}

# =============================================================================
# SCENARIO 3: User navigates with arrow keys
# =============================================================================
demo_scenario_3() {
    scenario_header "User presses down arrow - Navigation highlight moves"

    info_text "After typing '/sy', the user presses Down arrow. The selection highlight"
    info_text "moves to the next matching command. The inverted background shows current selection."
    echo

    show_prompt
    echo "/sy"
    echo

    # Get all commands and filter for /sy
    local -a all_cmds
    mapfile -t all_cmds < <(get_slash_commands)

    local -a filtered
    mapfile -t filtered < <(printf '%s\n' "${all_cmds[@]}" | filter_commands "sy")

    # Show with different selected indices
    echo -e "${INFO_COLOR}After 1st Down arrow press:${RESET}"
    render_demo_menu filtered 0
    echo

    echo -e "${INFO_COLOR}After 2nd Down arrow press:${RESET}"
    render_demo_menu filtered 1
    echo
}

# =============================================================================
# SCENARIO 4: User selects a command with Enter
# =============================================================================
demo_scenario_4() {
    scenario_header "User presses Enter - Command is selected and submitted"

    info_text "After typing '/sync' and pressing Enter, the menu closes, the selected"
    info_text "command is shown on the same line, and execution begins."
    echo

    show_prompt
    echo "/sync"
    echo
    echo "    /sync"
    echo
    echo -e "${INFO_COLOR}Selection confirmed. The command is displayed clearly and Claude receives the request...${RESET}"
    echo
}

# =============================================================================
# SCENARIO 5: Empty filter results
# =============================================================================
demo_scenario_5() {
    scenario_header "User types non-matching characters - Empty filter"

    info_text "When user types characters that don't match any command prefix,"
    info_text "the menu shows no items. Pressing Enter will submit the partial text"
    info_text "or the user can backspace to try again."
    echo

    show_prompt
    echo "/xyz"
    echo

    # Empty filtered results
    local -a empty
    render_demo_menu empty 0

    info_text "(No commands match '/xyz')"
    echo
}

# =============================================================================
# SCENARIO 6: Multiple similar commands
# =============================================================================
demo_scenario_6() {
    scenario_header "Multiple matches - User can navigate between options"

    info_text "Commands starting with similar prefixes are all shown. For example,"
    info_text "typing '/new' shows both '/new-feature' and '/new-feature-short'."
    echo

    show_prompt
    echo "/new"
    echo

    # Get all commands and filter for /new
    local -a all_cmds
    mapfile -t all_cmds < <(get_slash_commands)

    local -a filtered
    mapfile -t filtered < <(printf '%s\n' "${all_cmds[@]}" | filter_commands "new")

    echo -e "${INFO_COLOR}Selection on first match:${RESET}"
    render_demo_menu filtered 0
    echo

    echo -e "${INFO_COLOR}After Down arrow - Selection on second match:${RESET}"
    render_demo_menu filtered 1
    echo
}

# =============================================================================
# SCENARIO 7: Backspace - Reversing the filter
# =============================================================================
demo_scenario_7() {
    scenario_header "User presses Backspace - Filter expands again"

    info_text "Typing '/sync' then pressing Backspace deletes the 'c', reverting to '/syn'."
    info_text "The menu immediately shows commands matching the shorter prefix."
    echo

    show_prompt
    echo "/sync"
    echo

    # Get all commands and filter for /sync
    local -a all_cmds
    mapfile -t all_cmds < <(get_slash_commands)

    local -a filtered_sync
    mapfile -t filtered_sync < <(printf '%s\n' "${all_cmds[@]}" | filter_commands "sync")

    echo -e "${INFO_COLOR}After typing '/sync' (matches 'sync'):${RESET}"
    render_demo_menu filtered_sync 0
    echo

    # Now show after backspace
    echo -e "${INFO_COLOR}After pressing Backspace, now showing '/syn':${RESET}"
    local -a filtered_syn
    mapfile -t filtered_syn < <(printf '%s\n' "${all_cmds[@]}" | filter_commands "syn")
    render_demo_menu filtered_syn 0
    echo
}

# =============================================================================
# SCENARIO 8: Terminal state summary
# =============================================================================
demo_scenario_8() {
    scenario_header "Key Bindings Reference"

    echo -e "${SUBHEADER_COLOR}Navigation:${RESET}"
    echo "  • Up arrow         - Move selection up in the menu"
    echo "  • Down arrow       - Move selection down in the menu"
    echo "  • Type characters  - Filter commands by prefix"
    echo "  • Backspace        - Delete last character, expand filter"
    echo

    echo -e "${SUBHEADER_COLOR}Selection:${RESET}"
    echo "  • Enter            - Submit currently selected command"
    echo "  • Escape / Ctrl+C  - Cancel autocomplete, clear menu"
    echo "  • Ctrl+D           - Exit the REPL"
    echo
}

# =============================================================================
# MAIN DEMO
# =============================================================================

main() {
    demo_header "Interactive Slash Command Autocomplete UI Demo"

    echo "This demo shows how the autocomplete interface looks when using the 'cc' REPL."
    echo "The selected item is shown with inverted colors (white on black background)."
    echo

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
    sleep 1

    demo_scenario_7
    sleep 1

    demo_scenario_8

    echo
    demo_header "Demo Complete"
    echo "To use the actual autocomplete, start the REPL with:"
    echo
    echo -e "  ${SUBHEADER_COLOR}cc${RESET}"
    echo
    echo "Then type '/' to see the live autocomplete menu."
    echo
}

main "$@"

#!/bin/bash
# gum_mocks.sh - Mock gum commands for testing without gum dependency

mock_gum() {
    local subcommand="$1"
    shift

    case "$subcommand" in
        filter)
            # Parse arguments
            local value=""
            local placeholder=""
            local height=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --value=*) value="${1#*=}"; shift ;;
                    --value) value="$2"; shift 2 ;;
                    --placeholder=*) placeholder="${1#*=}"; shift ;;
                    --placeholder) placeholder="$2"; shift 2 ;;
                    --height=*) height="${1#*=}"; shift ;;
                    --height) height="$2"; shift 2 ;;
                    --no-limit=*) shift ;; # Ignore
                    --no-limit) shift ;;
                    *) shift ;;
                esac
            done

            # Read from stdin
            local input
            input=$(cat)

            # If value provided, return it (simulates pre-selection)
            if [[ -n "$value" ]]; then
                echo "$value"
                return 0
            fi

            # Otherwise return first line (simulates user selecting first item)
            if [[ -n "$input" ]]; then
                echo "$input" | head -n 1
                return 0
            fi

            # Empty input
            return 1
            ;;

        style)
            # Parse styling arguments and extract text
            local foreground=""
            local border=""
            local padding=""
            local text=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --foreground=*) foreground="${1#*=}"; shift ;;
                    --foreground) foreground="$2"; shift 2 ;;
                    --border=*) border="${1#*=}"; shift ;;
                    --border) border="$2"; shift 2 ;;
                    --padding=*) padding="${1#*=}"; shift ;;
                    --padding) padding="$2"; shift 2 ;;
                    *)
                        # This is the text to style
                        text="$1"
                        shift
                        ;;
                esac
            done

            # Just output the text without styling
            echo "$text"
            return 0
            ;;

        input)
            # Parse arguments
            local value=""
            local placeholder=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --value=*) value="${1#*=}"; shift ;;
                    --value) value="$2"; shift 2 ;;
                    --placeholder=*) placeholder="${1#*=}"; shift ;;
                    --placeholder) placeholder="$2"; shift 2 ;;
                    --prompt=*) shift ;; # Ignore
                    --prompt) shift 2 ;;
                    *) shift ;;
                esac
            done

            # Return value or mock input
            echo "${value:-mock-input}"
            return 0
            ;;

        write)
            # Parse arguments
            local value=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --value=*) value="${1#*=}"; shift ;;
                    --value) value="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done

            echo "${value:-mock-write-output}"
            return 0
            ;;

        confirm)
            # Always return success (yes) for automated tests
            return 0
            ;;

        choose)
            # Parse arguments
            local selected=""

            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --selected=*) selected="${1#*=}"; shift ;;
                    --selected) selected="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done

            # Read from stdin if available
            local input
            input=$(cat)

            if [[ -n "$selected" ]]; then
                echo "$selected"
            elif [[ -n "$input" ]]; then
                echo "$input" | head -n 1
            else
                echo "option1"
            fi
            return 0
            ;;

        *)
            echo "mock_gum: unknown subcommand: $subcommand" >&2
            return 1
            ;;
    esac
}

# Export for use in tests
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    export -f mock_gum
fi

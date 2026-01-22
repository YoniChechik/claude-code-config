#!/bin/bash

# Opens a file or directory in VS Code from any environment (WSL, Windows, Linux).
# Works by generating a temporary HTML page that triggers the vscode:// URL protocol,
# which is opened in the default browser to launch VS Code.
#
# Usage: open_vscode.sh [-n|--new-window] [path]
#   -n, --new-window    Attempt to open in a new window (experimental)

# Detect the runtime environment (WSL, Windows, or Linux)
# Returns environment type to determine correct vscode:// URL format and browser launch method
check_environment() {
    # SSH not supported - VS Code URL protocol requires local browser access
    if [[ -n "$SSH_CONNECTION" ]] || [[ -n "$SSH_CLIENT" ]]; then
        echo "Error: Opening VS Code via SSH is not supported currently" >&2
        exit 1
    fi

    if [[ -n "$WSL_DISTRO_NAME" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
        echo "windows"
    else
        echo "linux"
    fi
}

# Convert relative paths to absolute and validate path exists
get_absolute_path() {
    local target_path="${1:-$(pwd)}"

    # Convert relative to absolute path
    if [[ ! "$target_path" = /* ]]; then
        target_path="$(cd "$target_path" 2>/dev/null && pwd)"
    fi

    if [[ ! -e "$target_path" ]]; then
        echo "Error: Path does not exist: $target_path" >&2
        exit 1
    fi

    echo "$target_path"
}

# Generate the appropriate vscode:// URL based on environment
# WSL uses vscode-remote protocol, others use direct file protocol
generate_vscode_url() {
    local target_path="$1"
    local env_type="$2"
    local new_window="${3:-false}"

    local base_url
    case "$env_type" in
        wsl)
            # WSL requires remote protocol to open files in the WSL filesystem
            local wsl_distro="${WSL_DISTRO_NAME:-Ubuntu}"
            base_url="vscode://vscode-remote/wsl+${wsl_distro}${target_path}"
            ;;
        windows)
            base_url="vscode://file/${target_path}"
            ;;
        *)
            base_url="vscode://file/${target_path}"
            ;;
    esac

    # Append new window parameter (experimental - may not work on all versions)
    if [[ "$new_window" == "true" ]]; then
        echo "${base_url}?windowId=_blank"
    else
        echo "$base_url"
    fi
}

# Create temporary HTML page that auto-triggers the vscode:// URL
# The HTML auto-clicks a link to trigger the protocol handler, then closes itself
generate_html() {
    local vscode_url="$1"
    local temp_html="/tmp/open_vscode_$(date +%s).html"

    cat > "$temp_html" << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Opening VS Code...</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
            background-color: #1e1e1e;
            color: #ffffff;
        }
        .message {
            text-align: center;
        }
    </style>
</head>
<body>
    <div class="message">
        <h2>Opening VS Code...</h2>
        <a id="link" href="VSCODE_URL_PLACEHOLDER">Click here if VS Code doesn't open automatically</a>
    </div>
    <script>
        document.getElementById('link').click();
        setTimeout(() => window.close(), 1000);
    </script>
</body>
</html>
EOF

    sed -i "s|VSCODE_URL_PLACEHOLDER|${vscode_url}|g" "$temp_html"
    echo "$temp_html"
}

# Open the HTML file in the default browser using environment-specific methods
open_in_browser() {
    local temp_html="$1"
    local env_type="$2"

    case "$env_type" in
        wsl)
            # Convert WSL path to Windows path for PowerShell
            local windows_path=$(wslpath -w "$temp_html")
            powershell.exe -Command "Start-Process '$windows_path'"
            ;;
        windows)
            start "$temp_html"
            ;;
        *)
            xdg-open "$temp_html" 2>/dev/null || open "$temp_html" 2>/dev/null
            ;;
    esac

    # Clean up temp file after browser has loaded it
    (sleep 5 && rm -f "$temp_html") &
}

main() {
    local new_window="false"
    local target_arg="$1"

    # Check if -n or --new-window flag is provided
    if [[ "$1" == "-n" ]] || [[ "$1" == "--new-window" ]]; then
        new_window="true"
        target_arg="$2"
    fi

    local env_type=$(check_environment)
    local target_path=$(get_absolute_path "$target_arg")
    local vscode_url=$(generate_vscode_url "$target_path" "$env_type" "$new_window")
    local temp_html=$(generate_html "$vscode_url")

    open_in_browser "$temp_html" "$env_type"

    if [[ "$new_window" == "true" ]]; then
        echo "Opening VS Code in new window for: $target_path"
    else
        echo "Opening VS Code for: $target_path"
    fi
}

main "$@"

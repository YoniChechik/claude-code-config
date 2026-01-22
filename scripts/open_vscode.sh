#!/bin/bash

check_environment() {
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

get_absolute_path() {
    local target_path="${1:-$(pwd)}"

    if [[ ! "$target_path" = /* ]]; then
        target_path="$(cd "$target_path" 2>/dev/null && pwd)"
    fi

    if [[ ! -e "$target_path" ]]; then
        echo "Error: Path does not exist: $target_path" >&2
        exit 1
    fi

    echo "$target_path"
}

generate_vscode_url() {
    local target_path="$1"
    local env_type="$2"

    case "$env_type" in
        wsl)
            local wsl_distro="${WSL_DISTRO_NAME:-Ubuntu}"
            echo "vscode://vscode-remote/wsl+${wsl_distro}${target_path}"
            ;;
        windows)
            echo "vscode://file/${target_path}"
            ;;
        *)
            echo "vscode://file/${target_path}"
            ;;
    esac
}

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

open_in_browser() {
    local temp_html="$1"
    local env_type="$2"

    case "$env_type" in
        wsl)
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

    (sleep 5 && rm -f "$temp_html") &
}

main() {
    local env_type=$(check_environment)
    local target_path=$(get_absolute_path "$1")
    local vscode_url=$(generate_vscode_url "$target_path" "$env_type")
    local temp_html=$(generate_html "$vscode_url")

    open_in_browser "$temp_html" "$env_type"

    echo "Opening VS Code for: $target_path"
}

main "$@"

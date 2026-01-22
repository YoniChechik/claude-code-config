#!/bin/bash

# Get path argument or default to current directory
TARGET_PATH="${1:-$(pwd)}"

# Convert to absolute path if relative
if [[ ! "$TARGET_PATH" = /* ]]; then
    TARGET_PATH="$(cd "$TARGET_PATH" 2>/dev/null && pwd)"
fi

# Check if path exists
if [[ ! -e "$TARGET_PATH" ]]; then
    echo "Error: Path does not exist: $TARGET_PATH" >&2
    exit 1
fi

# Generate temporary HTML file
TEMP_HTML="/tmp/open_vscode_$(date +%s).html"

# Create HTML with vscode-remote URL
cat > "$TEMP_HTML" << 'EOF'
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

# Replace placeholder with actual vscode-remote URL
WSL_DISTRO="${WSL_DISTRO_NAME:-Ubuntu}"
VSCODE_URL="vscode://vscode-remote/wsl+${WSL_DISTRO}${TARGET_PATH}"
sed -i "s|VSCODE_URL_PLACEHOLDER|${VSCODE_URL}|g" "$TEMP_HTML"

# Convert to Windows path and open in browser
windows_path=$(wslpath -w "$TEMP_HTML")
powershell.exe -Command "Start-Process '$windows_path'"

# Clean up temp file after delay
(sleep 5 && rm -f "$TEMP_HTML") &

echo "Opening VS Code for: $TARGET_PATH"

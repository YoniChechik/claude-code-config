# Set Terminal Title

Renames the current terminal to a new title.

## New title from user input
"$ARGUMENTS"

### Validation
- If empty or missing: "Error: Terminal title is required. Please provide a new title."


## Usage
determine the new terminal title from user args and run:
```bash
curl -X POST http://localhost:$CLAUDE_HELPER_PORT -H "Content-Type: application/json" -d "{\"command\":\"setTerminalTitle\",\"args\":[\"$NEW_TITLE\",\"$CLAUDE_HELPER_CURRENT_TERMINAL_TITLE\"]}"
```

## Notes
- Uses `$CLAUDE_HELPER_CURRENT_TERMINAL_TITLE` to identify current terminal
- Falls back to active terminal if specified terminal not found

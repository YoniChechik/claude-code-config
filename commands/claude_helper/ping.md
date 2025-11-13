# Show Notification

Shows a notification in VS Code with optional message.

## Message from user input
"$ARGUMENTS"

### Validation
- If empty: Use default ping message
- If provided: Include in notification (can be fuzzy or free text)
## Usage
determine the message to show from user args and run:
```bash
curl -X POST http://localhost:3456 -H "Content-Type: application/json" -d "{\"command\":\"ping\",\"args\":[\"$MESSAGE\"]}"
```


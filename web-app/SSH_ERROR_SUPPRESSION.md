# Suppressing SSH "Connection Refused" Errors

## Problem
When restarting the Next.js server on port 6379, SSH port forwarding prints errors like:
```
channel 21: open failed: connect failed: Connection refused
```

These errors appear because SSH tries to forward the port while the server is temporarily down during restart.

## Solution Options

### Option 1: SSH Client Configuration (Recommended)
Add to your local SSH config (`~/.ssh/config` on your machine, NOT the server):

```
Host your-server-name
    LogLevel ERROR
    # or even quieter:
    # LogLevel QUIET
```

This reduces SSH verbosity and suppresses port forwarding errors.

### Option 2: VS Code SSH Configuration
If using VS Code Remote SSH, add to your VS Code settings.json:
```json
{
    "remote.SSH.logLevel": "error"
}
```

### Option 3: Command Line Flag
When connecting via SSH, use the quiet flag:
```bash
ssh -q user@host
```

### Option 4: Server-Side Mitigation (Already Implemented)
The `start-prod.sh` script has been optimized to:
- Wait longer (2s) for graceful shutdown
- Start the new server immediately after killing the old one
- Minimize the window where port 6379 is unavailable

This reduces (but doesn't eliminate) the connection refused errors.

## Why This Happens
1. User's SSH client forwards local port → remote port 6379
2. Server restart kills process on port 6379
3. Port temporarily unavailable
4. SSH client tries to connect → gets "connection refused"
5. SSH prints error to stderr
6. New server starts, SSH reconnects automatically

## Recommended Action
Configure your SSH client (Option 1) to suppress these harmless errors.

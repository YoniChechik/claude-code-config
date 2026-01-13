---
name: "permanent-cd"
description: "Change directory permanently in the REPL session"
---

Change directory to:

$ARGUMENTS

## Instructions

1. Validate the target directory exists using the Bash tool
2. If the directory exists:
   - Return `wanted_cwd` field with the absolute path to the target directory
   - Return a `response` field with confirmation message: "Changed to <path>"
3. If the directory does not exist:
   - Return only a `response` field with an error message
   - Do NOT return `wanted_cwd` field

## Important

- The `wanted_cwd` field MUST be an absolute path
- Only return `wanted_cwd` if the directory exists and is accessible
- After you return `wanted_cwd`, the shell will automatically cd to that directory and continue the session

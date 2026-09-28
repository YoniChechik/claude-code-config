---
name: "session-name"
description: "Assign or update a short label describing what this session is currently doing, stored in a per-session sidecar file so a status line can show it; inside iTerm2, also sets the raw OS-level tab title and triggers this tool's native rename command so the terminal title, session picker, and any companion app pick it up too"
argument-hint: "[optional forced name]"
---

1. Pick a short name (well under 35 characters) from `$ARGUMENTS` if given, otherwise from the current task and branch.
2. If you are a subagent (any depth), first `SendMessage(to: "main", ...)` with the name and reason, and use main's reply (confirmed or adjusted name). The top-level agent skips this.
3. Run the one script from this skill's base directory:

```bash
bash "<skill-base-dir>/rename_session.sh" "<name>"
```

Exit 10 means the name is unchanged (fine; say so). Exit 1 means an error (report it). Otherwise report the new name. Re-run whenever the topic drifts. The iTerm2 part briefly steals focus and sends a real keystroke, so never run it as a dry run in a live session.

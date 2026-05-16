---
name: "notify-waiting"
description: "Ping the user with an audible chime, green iTerm2 tab color, and a 'waiting...' terminal title to grab their physical attention. Invoke this WHENEVER Claude is about to block on a manual user action that requires the user to be at their machine — e.g., right before `gcloud auth login`, 2FA approval prompts, manual OAuth browser confirmations, or any interactive CLI step that pauses until the user clicks/approves something."
---

Run the one-liner below to alert the user. If orchestration mode is on, dispatch it via a subagent Bash call; otherwise run it directly in the current Bash tool. No other steps.

```bash
bash -c 'source /Users/yonichechik/.claude/scripts/_notify.sh && notify_user_attention'
```

---
name: "ci"
description: "Run the CI watcher script for the current or specified branch"
argument-hint: "[branch]"
---

CI watcher: always-on background process that monitors CI and notifies on both failure and pass via webhook channel.
Launch once per feature — the watcher never exits, so no re-launch is needed.

# step 1: parse branch name from user input

## user input
"$ARGUMENTS"

## parse branch name
If user input is provided- determine branch name from it. If not, determine the current branch:
```bash
git branch --show-current
```

# step 2: check if watcher is already running for this session

Before launching, check if `ci_watch_persistent.sh` is already running as a descendant of the current Claude session. Run this bash snippet and check the output:

```bash
NODE=$(which node 2>/dev/null || echo /usr/local/bin/node)
REGISTRY="$HOME/.claude_session_id_to_port"
BRANCH="<branch>"

# Get all registered Claude PIDs
CLAUDE_PIDS=$("$NODE" -e "
  const r = JSON.parse(require('fs').readFileSync(process.argv[1], 'utf8'));
  console.log(Object.keys(r).join('\n'));
" -- "$REGISTRY" 2>/dev/null)

# Build ordered ancestor list for current shell
MY_ANCESTORS=()
PID=$$
while [ "$PID" -gt 1 ]; do
  MY_ANCESTORS+=("$PID")
  PID=$(ps -p "$PID" -o ppid= 2>/dev/null | tr -d ' ')
  [ -z "$PID" ] && break
done

# Find closest Claude session PID (LCA logic from notify.sh)
CLAUDE_SESSION_PID=""
BEST_DEPTH=99999
for CPID in $CLAUDE_PIDS; do
  ps -p "$CPID" > /dev/null 2>&1 || continue
  WALK="$CPID"
  while [ "$WALK" -gt 1 ]; do
    IDX=0
    for ANC in "${MY_ANCESTORS[@]}"; do
      if [ "$ANC" = "$WALK" ]; then
        if [ "$IDX" -lt "$BEST_DEPTH" ]; then
          BEST_DEPTH="$IDX"
          CLAUDE_SESSION_PID="$CPID"
        fi
        break 2
      fi
      IDX=$((IDX + 1))
    done
    WALK=$(ps -p "$WALK" -o ppid= 2>/dev/null | tr -d ' ')
    [ -z "$WALK" ] && break
  done
done

# Check if ci_watch_persistent.sh for this branch is already a descendant of the session
if [ -n "$CLAUDE_SESSION_PID" ]; then
  WATCHER_PIDS=$(pgrep -f "ci_watch_persistent.sh $BRANCH" 2>/dev/null || true)
  for WPID in $WATCHER_PIDS; do
    WALK="$WPID"
    while [ "$WALK" -gt 1 ]; do
      if [ "$WALK" = "$CLAUDE_SESSION_PID" ]; then
        echo "DUPLICATE:$WPID"
        break 2
      fi
      WALK=$(ps -p "$WALK" -o ppid= 2>/dev/null | tr -d ' ')
      [ -z "$WALK" ] && break
    done
  done
fi
```

If the output contains `DUPLICATE:<pid>`, print this message and **stop** — do NOT proceed to step 3:
```
CI watcher is already running for this session (branch: <branch>, PID: <pid>). No need to re-launch.
```

If there is no `DUPLICATE` output, proceed to step 3.

# step 3: run the CI watcher script in the background for the specified branch

Run this command in the background (start once, forget it):
```
bash ~/.claude/scripts/ci_watch_persistent.sh <branch>
```


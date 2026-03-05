# Plan: Merge 3 Startup Hooks Into One

## Goal
Merge the 3 SessionStart hooks (validate_env, git_sync_on_start, cleanup_untracked_clones) into a single script. Remove coloring. Simplify git branch state to just check if pull works.

## Changes

### 1. Create unified startup script `scripts/startup.sh`
- Combine all 3 scripts into one
- Remove all ANSI color codes
- Simplify git branch state: just try `git pull`, report success or error
- Output a single JSON systemMessage

### 2. Update `settings.json`
- Replace 3 SessionStart hooks with 1

### 3. Delete old scripts
- `scripts/validate_env.sh` - merged into startup.sh
- `scripts/git_sync_on_start.sh` - merged into startup.sh
- `scripts/cleanup_untracked_clones.sh` - merged into startup.sh
- `scripts/git_branch_state.sh` - no longer needed (simplified)

## Output Format (no colors, single block)
```
Environment: OK (or list issues)
Git: pulled OK / error: <message>
Clones: <existing list> / <removed list>
```

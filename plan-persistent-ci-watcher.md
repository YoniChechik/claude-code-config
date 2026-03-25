# Feature: Persistent CI Watcher

## TLDR
Replace the one-shot `ci_watch.sh` with an exit-and-relaunch pattern: the orchestrator launches `ci_watch_persistent.sh` via `run_in_background=true`, the script exits on terminal events (CI pass/fail/conflict/timeout) with descriptive output, the orchestrator handles the result and relaunches as needed.

## Research and References

### How the current system works

1. **`post_tool_use__ci_push.sh`** - PostToolUse hook that fires on `git push`/`gh pr create`. Outputs JSON `additionalContext` instructing the current agent to run `ci_watch.sh` with `run_in_background=true`.

2. **`ci_watch.sh`** - Polls CI status every 5s for up to 10 minutes. Exits with status messages on pass/fail/timeout. Checks merge conflicts.

3. **The problem**: Subagents push code, hook tells subagent to run watcher, but subagent closes and kills the background process. The orchestrator never sees the CI result.

### New approach: Exit-and-Relaunch from Orchestrator

The orchestrator owns the watcher lifecycle. It launches `ci_watch_persistent.sh <branch>` with `run_in_background=true` as part of the feature-loop-scheme. Since `run_in_background` notifies on process exit, the watcher exits when it has something to report. The orchestrator gets notified, handles the result (delegates fix to coder-agent if needed), and relaunches the watcher.

**Flow:**
1. Orchestrator launches `ci_watch_persistent.sh <branch>` with `run_in_background=true` after PR creation or implementation starts
2. Watcher polls: checks if PR exists, then polls CI status every 5s
3. On terminal event (CI fail, merge conflict, CI pass, timeout), the process EXITS with descriptive stdout
4. Orchestrator gets notified with the output
5. If CI failed or merge conflict: orchestrator delegates fix to coder-agent, then relaunches watcher
6. If CI passed: done, no relaunch needed

**Why this works:**
- The orchestrator lives for the entire session, so it always receives the notification
- No subagent lifecycle dependency
- No filesystem IPC needed
- The hook becomes a safety net reminder, not the primary launch mechanism

### What to keep from current ci_watch.sh
- Core polling logic (`gh run list`, filter by SHA, dedup by workflow name)
- Merge conflict detection (`gh pr view --json mergeable`)
- Failed job reporting with `gh run view <id> --log-failed`
- SHA tracking to detect newer pushes

### What changes
- Orchestrator proactively launches the watcher (not triggered by hook)
- Script output includes clear instructions for the orchestrator (e.g., "CI FAILED: delegate fix to coder-agent, then relaunch this watcher")
- Hook simplified to just a reminder if orchestrator forgot
- Script exits on every terminal event (no persistent loop across push cycles)

## Tasks

### Task 1: Create ci_watch_persistent.sh
**What:**
- Create `scripts/ci_watch_persistent.sh` based on `scripts/ci_watch.sh` but adapted for the exit-and-relaunch pattern
- Takes branch name as argument
- Polls CI status every 5s with a 10-minute timeout (same as current)
- On terminal events, EXITS with descriptive stdout messages that tell the orchestrator what to do:
  - CI passed: "CI passed on branch '$BRANCH'. All workflows green."
  - CI failed: includes failed workflow names, failed jobs, `gh run view <id> --log-failed` command, AND instruction: "Delegate fix to coder-agent, then relaunch this watcher with: `$HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH`"
  - Merge conflict: "PR on branch '$BRANCH' has merge conflicts. Delegate conflict resolution to coder-agent, then relaunch this watcher."
  - Timeout: report timeout with relaunch instruction
  - Newer push detected: exit cleanly (orchestrator should have already launched a new watcher for the new push)
- Keep: polling logic, SHA tracking, dedup by workflow, merge conflict detection, failed job log fetching

### Task 2: Update feature-loop-scheme skill
**What:**
- Modify `skills/feature-loop-scheme/SKILL.md`
- Add a CI watcher launch step after PR creation (Step 5): orchestrator runs `$HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH` with `run_in_background=true`
- Add instructions that when the watcher reports back:
  - On failure/conflict: delegate fix to coder-agent, commit and push, then relaunch watcher
  - On pass: proceed to next step

### Task 3: Update orchestrator instructions
**What:**
- Modify `CLAUDE_append_to_user_prompt_main_agent_only.md`
- Add explicit exception: orchestrator MAY run `ci_watch_persistent.sh` with `run_in_background=true` using the Bash tool
- Add instructions for handling watcher notifications (the relaunch pattern)

### Task 4: Simplify post_tool_use__ci_push.sh hook
**What:**
- Simplify `scripts/post_tool_use__ci_push.sh`
- The hook no longer needs to instruct anyone to run the watcher (orchestrator does it proactively via feature-loop-scheme)
- Change the hook to just output a reminder: "REMINDER: If you haven't already, launch the CI watcher with run_in_background=true: `$HOME/.claude/scripts/ci_watch_persistent.sh $BRANCH`"
- Keep the existing detection logic (git push / gh pr create) and the PR/workflow existence checks

### Task 5: Delete old ci_watch.sh
**What:**
- Delete `scripts/ci_watch.sh`
- No other files reference it after Task 4 updates the hook

### Task 6: Update tests
**What:**
- Update `tests/test_ci_watch_merge_conflicts.bats` to test `ci_watch_persistent.sh` instead of `ci_watch.sh`
  - Core merge conflict detection logic is the same
  - Verify exit messages include relaunch instructions
- Update `tests/test_post_tool_use__ci_push.bats` to verify:
  - Hook outputs `additionalContext` mentioning `ci_watch_persistent.sh` (not `ci_watch.sh`)
  - Message is a reminder (not a blocking requirement)

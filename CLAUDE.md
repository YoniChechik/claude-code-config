Be concise. No unnecessary detail.

ALWAYS USE TASKS! EVEN FOR SIMPLE 1 BLOCK TASKS! ALWAYS SHOW TASK STATUS!

COMMIT AND PUSH FREQUENTLY!

NO backward compatibility. Delete unused code completely. Only keep backward compatibility if explicitly requested by the user.

## Feature Development Workflow

We use isolated git clones (NOT worktrees) for feature development. Each feature gets its own clone under `<repo>/_clones/<feature-name>`, created from the remote origin with its own branch. NEVER edit code directly in the main project directory — always work inside a clone dir. After creating or resuming a clone, cd into it using `/cd-permanent` so all subsequent work happens in the clone directory. When starting new work, run `/new-feature` which creates the clone, sets up the branch, and runs the full planning/dev workflow. To resume existing feature work, use `/continue-feature`. This ensures clean separation between features and prevents accidental changes to main. We have base directory protection hooks that block edits in the main repo dir — if you encounter them, it means you're not working inside a clone and need to create/resume one first.

NEVER use the `EnterPlanMode` tool. Use the `/plan` skill instead when planning is needed.

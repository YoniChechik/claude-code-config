Be concise. No unnecessary detail.

ALWAYS USE TASKS! EVEN FOR SIMPLE 1 BLOCK TASKS! ALWAYS SHOW TASK STATUS!

COMMIT AND PUSH FREQUENTLY!

NO backward compatibility. Delete unused code completely. Only keep backward compatibility if explicitly requested by the user.

## Feature Development Workflow

We use isolated git clones (NOT worktrees) for feature development. Each feature gets its own clone under `<repo>/_clones/<feature-name>`, created from the remote origin with its own branch. NEVER edit code directly in the main project directory — always work inside a clone dir. After creating or resuming a clone, cd into it using `/cd-permanent` so all subsequent work happens in the clone directory. When starting new work, run `/feature-new` which creates the clone, sets up the branch, and runs the full planning/dev workflow. To resume existing feature work, use `/feature-continue`. This ensures clean separation between features and prevents accidental changes to main. We have base directory protection hooks that block edits in the main repo dir — if you encounter them, it means you're not working inside a clone and need to create/resume one first.

## Agent Preferences

When spawning subagents via the Task/Agent tool, always prefer our custom agents over the built-in default types:
- Use `planner-agent` instead of the built-in `Plan` subagent type
- Use `coder-agent` instead of the built-in `general-purpose` (Code) subagent type
- The built-in `Explore` type is acceptable for quick read-only codebase searches
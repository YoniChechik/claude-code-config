Be concise. No unnecessary detail.

ALWAYS USE TASKS! EVEN FOR SIMPLE 1 BLOCK TASKS! ALWAYS SHOW TASK STATUS!

COMMIT AND PUSH FREQUENTLY!

NO backward compatibility. Delete unused code completely. Only keep backward compatibility if explicitly requested by the user.

## Main Agent Orchestration Rules

The main agent is an ORCHESTRATOR. It delegates ALL execution to subagents via the Task tool.

### NEVER use directly from main agent:
- Bash tool (delegate to coder-agent or Bash subagent)
- Edit / Write tools (delegate to coder-agent)
- MCP tools (delegate to appropriate subagent)

### ALLOWED from main agent:
- Read, Glob, Grep (for routing context only)
- Task tool (to spawn subagents)
- ToolSearch (to discover tools for subagents)

### When tempted to run Bash or Edit directly:
STOP. Wrap it in a Task call instead. Even a single command like `git status` should go through a Bash subagent.

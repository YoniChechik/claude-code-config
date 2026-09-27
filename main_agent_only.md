# ORCHESTRATOR / MAIN AGENT ONLY

**ALWAYS REMEMBER:** YOUR ROLE IS ORCHESTRATION ONLY

**YOU DO NOT WRITE CODE. YOU DO NOT RUN CODE. YOU DELEGATE.**

## The orchestrator MAY ONLY:
- Spawn subagents for implementation work
- Communicate with the user
- Use the question tool to ask the user for clarification

## The orchestrator MUST NOT:
- Edit or Write any file directly
- Use MCP tools directly
- Do code analysis requiring deep understanding
- Run code or tests — ALL bash commands should be done by some subagent

## Exceptions (the orchestrator MAY act directly when):
- The user explicitly authorizes direct execution in their prompt (e.g., "go ahead and edit", "run this yourself", "no need to delegate")
- It is executing instructions from a Skill (the skill flow itself tells it to run bash/edit/use tools — follow the skill's instructions)
- >2 subagent failures in a row- just run it yourself in the FG.

## Subagent types
Use opus for planning and long coding sessions.
Use sonnet for short and easy tasks / when runnnig "fast new-feature"

## subagent scope
Each subagent should do one task/step out of a full feature plan.

## Parallelism
Default to parallel work. Before starting any multi-step task, always think about how to split it across multiple subagents running in parallel — do not default to a serial plan. When a task splits into independent pieces, split it and run subagents in parallel instead of doing the work serially. When you plan a multi-step task, structure the plan so steps that do not depend on each other run in parallel.

# Feature Development — MANDATORY WORKFLOW

the. "/new-feature" skill is the most basic skil we have- and we use it 95% of the time. this should be invoced on new features. here it is printed in trhe main prompt as well:

@skills/new-feature/SKILL.md

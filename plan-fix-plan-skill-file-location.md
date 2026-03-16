# Feature: Fix Plan Skill File Location Bug

## TLDR
The plan skill writes plan files to `~/.claude/plans/` (a global directory) instead of the clone repo directory. This happens because the built-in `EnterPlanMode`/`ExitPlanMode` tools force writing to `~/.claude/plans/`. Fix by removing `EnterPlanMode`/`ExitPlanMode` entirely and having the skill directly explore the codebase and write the plan file to the current working directory.

## Research and References

The built-in `EnterPlanMode` tool injects a system-reminder saying: "You should create your plan at `~/.claude/plans/<random-name>.md`. NOTE that this is the only file you are allowed to edit." This cannot be changed — it's built into Claude Code. The plan skill's current Step 4 asks the agent to write `plan-$FEATURE_NAME.md` to the clone directory DURING plan mode, which is impossible due to the system restriction. The IMPORTANT note on line 64 tries to say "after exiting plan mode, write the plan file" but it's buried inside Step 5 ("Exit Plan Mode") and gets ignored.

Additionally, `ExitPlanMode` accepts an `allowedPrompts` parameter that triggers the "bypass permission mode" dialog. The current skill doesn't mention this, so the user doesn't get the expected approval flow after planning.

Secondary issue: `sync/SKILL.md` and `pr-create/SKILL.md` reference `plan_*.md` (underscore) but plan files are now named `plan-$FEATURE_NAME.md` (hyphen).

### Task 1: Rewrite plan/SKILL.md - Remove EnterPlanMode/ExitPlanMode entirely
**What:**
- Remove all references to `EnterPlanMode` and `ExitPlanMode` tools
- Simplify to 2 steps: "Explore & Plan" and "Write Plan File"
- Use explorer subagent for codebase exploration instead of plan mode
- Write plan file directly to current working directory as `plan-$FEATURE_NAME.md`

### Task 2: Fix plan file name pattern in sync and pr-create skills
**What:**
- `skills/sync/SKILL.md` lines 73, 91: Change `plan_*.md` → `plan-*.md`
- `skills/pr-create/SKILL.md` lines 20, 26: Change `plan_*.md` → `plan-*.md`

### Task 3: Manual verification
**What:**
- Start a new feature with `/new-feature` in a test repo
- Verify the plan file is written to the clone directory (not `~/.claude/plans/`)
- Verify `/continue-feature` can find the plan file

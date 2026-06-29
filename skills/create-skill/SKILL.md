---
name: "create-skill"
description: "Use this skill when creating a new Claude Code skill. Ensures the skill is created in the closest `.claude` directory (the nearest parent git repo's `.claude`)."
---

When creating skills, always create them in the closest `.claude` directory. For example, if `pwd == _worktrees/some-feature`, create the skill in `_worktrees/some-feature/.claude/skills/<skill-name>/`. The "closest" means the nearest parent git repo's `.claude` directory.

When done creating the skill, be extra verbose: print the entire final content of the SKILL.md file, and explain any extra scripts/helpers added alongside it, so the user can review and approve.

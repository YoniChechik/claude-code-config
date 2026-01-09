---
name: structure-agent
description: Enforces top-to-bottom code organization and naming.
---

# Structure Agent

Enforce proper code structure in each file.

## Code Organization (Top to Bottom)
1. Public constants
2. Public classes
3. Main/public functions
4. Private constants (`_CONST`)
5. Private classes (`_HelperClass`)
6. Private functions (`_helper_func`)

## Rules
- All private items MUST start with `_` prefix
- No relative imports (use absolute imports)

Report what was reorganized.
Commit and push changes.

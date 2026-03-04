---
name: structure-agent
description: Enforces top-to-bottom code organization and naming.
---

# Structure Agent

Enforce proper code structure in each file- Code should be "Top to Bottom"- meaning organized from most important and general to least important and specific. This makes it easier to read and understand code.

## Code Organization
1. Constants (public, then private)
2. Public classes
3. Main/public functions
4. Private classes 
5. Private functions

## Rules
- No relative imports (use absolute imports)
- Python Specific: All private items MUST start with `_` prefix

## Results
Report what was reorganized.
Commit and push changes.

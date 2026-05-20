---
name: "brainstorm"
description: "Interactive thinking partner for vague ideas. Use when the user has a fuzzy idea and wants to explore it before any plan or code — 'help me think through X', 'I'm not sure how to approach Y', 'let's brainstorm Z'. Distinct from /plan (produces structured plan) and /ask (answers questions). Use for the fuzzy front-end only."
argument-hint: "[topic]"
---

# Brainstorm Mode

Thinking partner. Do NOT write code. Do NOT edit files (except the final artifact at the end).

## Topic from user
"$ARGUMENTS"

If empty, ask the user what they want to explore.

## Process

### Dialogue loop
- Ask probing/clarifying questions **one or two at a time**. No walls of questions.
- For concrete choices, use AskUserQuestion. For open-ended prompts, use plain text.
- At key decision points, surface **2-4 angles or options** so the user has something concrete to react to. Include tradeoffs for each.
- Challenge assumptions gently. Name the tradeoff out loud.
- Track threads. If the user goes vague, reflect back what you heard and pick one branch to deepen.

### Stop conditions
Stop when the user signals done: "ok let's go with X", "that's enough", "let's plan it", "good, write it up", etc.

### Artifact
Derive a short kebab-case slug from the topic. Write `/tmp/brainstorm_<slug>.md` containing:

```markdown
# Brainstorm: <Topic>

## Original prompt
<verbatim from user>

## Key questions explored
- ...

## Options considered
### Option A: <name>
- Tradeoffs: ...
### Option B: <name>
- Tradeoffs: ...

## Conclusion / direction
<chosen direction, or "no decision yet">

## Open questions
- ...
```

After writing, tell the user the path. If a direction was chosen, suggest `/plan` as the next step.

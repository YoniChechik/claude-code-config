---
name: "adhd"
description: "ADHD-style output: short chunks, one item at a time, plain words, user says 'go' to advance. Works for plans, explanations, reviews — any long answer."
argument-hint: "[topic]"
---

# ADHD Output Style

Break a long or multi-part answer into short pieces. User paces it with "go".


## Pattern

1. One short sentence: what this is about.
2. Numbered list of item names only. No explanations yet.
3. Stop. Wait for "go" / "next".
4. On "go", cover one item. Short sentences, plain words. Explain jargon in one line if you must use it. No tables, no long paragraphs. End with: "Say 'go' for the next one."
5. Anything else (question, pushback, "explain more") means stay on this item. Answer it directly. Only advance on "go" — or a reply that clearly resolves a question that item asked.
6. add titles to separate concerns

## Mid-conversation additions

Something new comes up (research result, user raises a new point)? Queue it. Present it later the same way — one line, wait for "go". Do not dump it in immediately.

## Rules

No tables. No long paragraphs. Short bullets or lines. Plain words over jargon.

## If it was a plan

Once every item is resolved, and this is a coding project with Linear: turn it into tracked work — one epic, one sub-issue per item, matching this workspace's existing conventions. Delegate the creation to a subagent with Linear tools.

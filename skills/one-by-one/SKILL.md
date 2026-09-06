---
name: "one-by-one"
description: "Present a list one item at a time. User says 'next' or 'go' to advance, or asks a question to stay on the item. Claude's own questions are phrased yes/no. Uses the adhd-structure skill to format each item's content."
argument-hint: "[topic]"
---

# One By One

Pace a multi-item answer. One item per turn.

## Pattern

1. One short line: what this is about.
2. Numbered list of item names only — no content yet.
3. Stop. Wait for "next" or "go".
4. On "go", write that item using the adhd-structure format (1-line summary → 5-line version → deeper detail on request).
5. End the item with: "Say 'next' for the next one."
6. Anything else — pushback, a question, "explain more" — means stay on this item. Answer it directly. Advance only on "next"/"go", or a reply that clearly resolves a question this item asked.

## Claude's questions

If Claude needs to ask the user something mid-walkthrough, phrase it yes/no. Tell the user to answer "y" or "n".

Bad: "Update tests too, or just docs, or both?"
Good: "Update tests too? (y/n)"

## New items mid-walkthrough

Something new comes up? Queue it. Present it later the same way — one line, wait for "next". Do not dump it in immediately.

## Rules

No tables. No long paragraphs. Short bullets or lines.

## If it was a plan

Once every item is resolved, and this is a coding project with Linear: turn it into tracked work — one epic, one sub-issue per item, matching this workspace's existing conventions. Delegate the creation to a subagent with Linear tools.

---
name: "one-by-one"
description: "Present a list one item at a time, every item numbered. User says 'next' or 'go' to advance, or asks a question to stay on the item. Claude's own questions favor numbered alternatives, yes/no, or 'go' for a stated default, to keep replies short. Uses the adhd-structure skill to format each item's content. Logs answers without acting until every item is resolved, and survives interruptions (subagent/monitor notifications) by logging them too and reprinting the pending question."
argument-hint: "[topic]"
---

# One By One

Pace a multi-item answer. One item per turn. Every item is numbered, start to finish.

## Pattern

1. One short line: what this is about.
2. Numbered list of item names only — no content yet.
3. Stop. Wait for "next" or "go".
4. On "go", write that item using the adhd-structure format (1-line summary → 5-line version → deeper detail on request). Keep its number in view (e.g. "Item 2 of 5").
5. If the item is a real decision/question, end it with a short recommendation and the lowest-effort way to answer (see "Claude's questions"). If the item is purely informational (nothing to decide), skip the recommendation entirely — just present the information.
6. End the item with: "Say 'next' for the next one" — or, if it asked a question, with that question instead.
7. Anything else — pushback, a question, "explain more" — means stay on this item. Answer it directly. "Next" is the only advance word; saying it closes the current item AS-IS (whatever state it's in after the discussion — accepted, revised, whatever was last said) and moves to the next one. There is no separate accept-then-advance step: reaching "next" IS the approval, nothing more to confirm.

## Claude's questions

Phrase every mid-walkthrough question so the reply can be as short as possible:
- Numbered alternatives when there's more than one real option — tell the user to reply with a number.
- Yes/no ("y"/"n") when there are exactly two.
- "Say 'go' to accept the default" whenever there's an obvious recommended choice — name it.

Bad: "Update tests too, or just docs, or both?"
Good: "1) tests too  2) docs only  3) both (recommended — say 'go')"

## Log, don't act

Never act on an answer while items remain unresolved. Log each answer as it comes in and move to the next item. Apply everything only after every item in the walkthrough has been answered.

This applies to ANYTHING that surfaces mid-walkthrough, not just answers to the item on screen — a request to edit an unrelated file, change a setting, fix this very skill, or do some other one-off task. Log it as a queued action exactly like a new item (see "New items mid-walkthrough") and say so in one line, then continue the walkthrough. Do not act on it immediately, even if it looks small or purely mechanical — the whole point of deferring is that the user is mid-flow on the list and shouldn't be interrupted by a side-effect landing out of order. Act on it only in the "Wrapping up" pass, unless the user explicitly says to do it right now (e.g. "do this immediately," "don't wait").

## Reprint the pending question

Something else can land mid-walkthrough — a subagent finishing, a monitor notification, an unrelated message. Log it too (don't act on it yet either), and in that same reply still end by reprinting the currently-pending item's question exactly as before, so it never gets buried by the interruption.

## New items mid-walkthrough

Something new comes up? Queue it. Present it later the same way — one line, wait for "next". Do not dump it in immediately.

## Wrapping up

Once every item is resolved (and every logged interrupt has been addressed):
1. Print a short numbered summary of every decision made and every action now queued.
2. Explicitly ask the user to confirm before starting work on all of it.
3. Only after that confirmation, act on everything — including any interrupts logged along the way.

If it was a plan and this is a coding project with Linear: instead of, or alongside, that summary, turn it into tracked work — one epic, one sub-issue per item, matching this workspace's existing conventions. Delegate the creation to a subagent with Linear tools.

## Rules

No tables. No long paragraphs. Short bullets or lines.

---
name: "next-steps"
description: "Surface every open end blocking work — next steps, open tickets, and pending decisions — as a list of 3-sentence items grouped under Open Ends. Ends by offering to walk through them one by one. Use when the user asks 'what's next', 'next steps', 'open ends', 'what decisions are left', 'what do you need from me', or /next-steps."
---

# Next Steps

List every open end for the current work: next actions, open tickets, and decisions still blocking progress.

## Step 1: Build the list

Scan the current session for:
- Concrete next actions (code not yet written, tests not yet run, PR not yet opened).
- Open tickets (Linear/GitHub issues referenced but not resolved).
- Pending decisions: questions already asked and unanswered, forks/tradeoffs a subagent flagged instead of deciding, anything you were about to ask before this skill ran.
- Anything else genuinely open: a running background task, a flagged risk, a leftover TODO.

Exclude:
- Anything already done or already answered.
- Calls you can reasonably make yourself per existing conventions (CLAUDE.md, an ADR, an established pattern).
- Pure physical actions only the user can do (click, type a card number, approve OAuth) — that's `human-action-needed`, not this list.

Order: anything blocking a running subagent, CI, or a deploy goes first. Cosmetic/low-stakes goes last.

If there are truly no open ends, say so in one line instead of forcing a list.

## Step 2: Write each item as 3 sentences

Under one heading "Open Ends", write exactly 3 sentences per item:
1. What it is, concretely — the file, ticket, or step.
2. Why it's open — blocked on what, or what breaks if skipped.
3. What happens next, or the recommended default if there is one.

No sub-headers per item, no sub-bullets, no tables. Plain words, no preamble.

## Step 3: Offer to walk through them

After the list, ask exactly one question: "Want to go over them one by one?"

- Yes → invoke the `one-by-one` skill on this list (it formats each item with `adhd-structure`).
- No → stop; let the user act on whichever item(s) they choose.

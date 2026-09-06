---
name: "next-steps"
description: "Surface every OPEN end blocking work — next actions, open tickets, pending decisions — as a short numbered list (title, one-line description, one-line why-it's-open, short recommendation) grouped under Open Ends. Never lists what's already done. Ends by offering to walk through them one by one. Use when the user asks 'what's next', 'next steps', 'open ends', 'what decisions are left', 'what do you need from me', or /next-steps."
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

## Step 2: Write each item short, numbered

Under one heading "Open Ends", number every item (1, 2, 3…). Each item gets exactly, on as few lines as possible:
- **Title** — a few words naming it.
- One-line description — the concrete file, ticket, or step.
- One-line explanation of why it's open — blocked on what, or what breaks if skipped.
- A short recommendation — the default to take if the user just says "go".

No 3-sentence prose, no sub-headers, no sub-bullets, no tables. Only OPEN items — never mention what's already done or already answered; this is not a changelog.

## Step 3: Offer to walk through them

After the list, ask exactly one question: "Want to go over them one by one?"

- Yes → invoke the `one-by-one` skill on this list.
- No → stop; let the user act on whichever item(s) they choose.
- If the user's own request already asked for "next steps" and "one by one" together, skip this question and go straight into the `one-by-one` walkthrough.

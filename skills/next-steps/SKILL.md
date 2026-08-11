---
name: "next-steps"
description: "Write the needed next steps for the current work: numbered, terse by default, with a short reason added only where it's non-obvious or high-stakes. Ends with a question asking whether to proceed now. Use when the user asks 'what's next', 'next steps', 'open ends', or /next-steps."
---

# Next Steps

Output a numbered list of the concrete next steps for the current context/branch/task.

Rules:
- One line per step, imperative, max ~12 words for the step itself.
- Add a short follow-up sentence (max ~2) under a step ONLY when the step is
  non-obvious, risky, or its importance/context isn't self-evident from the
  imperative line alone — e.g. why it matters, what breaks if skipped, or what
  was found. Trivial/mechanical steps stay a bare one-liner with no follow-up.
- No sub-bullets, no code blocks unless a command IS the step.
- Only real remaining steps — skip anything already done. If there are truly
  none, say so in one line instead of forcing a list.
- Prefer 3-7 steps; fewer is better.
- No preamble, no recap, no headers, no tables.
- End with exactly one short question, e.g. "Start with 1 now?" or "Do all of these now?"

If the current work/context is unclear, ask one clarifying question instead of guessing.

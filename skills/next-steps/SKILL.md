---
name: "next-steps"
description: "Write the needed next steps for the current work: numbered, one line each, no prose. Ends with a question asking whether to proceed now. Use when the user asks 'what's next', 'next steps', or /next-steps."
---

# Next Steps

Output a numbered list of the concrete next steps for the current context/branch/task.

Rules:
- One line per step, imperative, max ~12 words each.
- No sub-bullets, no explanations, no code blocks unless a command IS the step.
- Only real remaining steps — skip anything already done.
- Prefer 3-7 steps; fewer is better.
- No preamble, no recap, no headers, no tables.
- End with exactly one short question, e.g. "Start with 1 now?" or "Do all of these now?"

If the current work/context is unclear, ask one clarifying question instead of guessing.

---
name: "debug"
description: "When you get a failed result/error/user says its wrong/its a bug, use this skill to systematically debug and fix the problem."
---

# Debugging Workflow

Always work based on data. Never guess. ALWAYS run as subagent (opus high effort).

### 1. Understand the Error
- Identify the failing test or error scenario from trace or user report
- Pin down expected vs actual behavior in the user's own terms
- Read the error message and stack trace if available

### 2. Build a Feedback Loop
Pick the highest option that fits — a loop you can run, not a plan to read code.
1. Failing test at the right seam (real code path, minimal mocking)
2. curl/HTTP script against a dev server
3. CLI invocation diffed against known-good output
4. Headless browser script (Playwright)
5. Replay a captured trace/payload
6. Throwaway minimal harness
7. Property/fuzz loop — for "sometimes wrong" bugs
8. Bisection harness for regressions (`git bisect run`)
9. Differential loop — old vs new, or working vs broken input

### 3. Gate: Is the Loop Good Enough?
Do not proceed until all four hold:
- **Red-capable** — asserts the user's exact symptom, not "didn't crash"
- **Deterministic** — pin time, seed RNG, freeze network
- **Fast** — seconds, not minutes
- **Agent-runnable** — you can name one command you have already run at least once

**Stop rule:** if you're reading code to build a theory before that command exists, stop. That's the exact failure this skill prevents.

**Non-deterministic bugs:** the goal is a higher reproduction rate, not a clean repro. Loop the trigger, parallelise, inject sleeps. 50% flake is debuggable; 1% is not.

### 4. Minimise
Once red, shrink to the smallest scenario that still goes red. Cut inputs/callers/config one at a time, re-running after each cut. Done when every remaining element is load-bearing. This shrinks the hypothesis space and becomes your regression test.

### 5. Rank Multiple Hypotheses
Generate 3-5 ranked hypotheses **before testing any** — single-hypothesis generation anchors on the first plausible idea.
- Generation prompts: logic errors (wrong algorithm/condition), type errors (wrong types passed/returned), edge cases (unhandled boundaries), import/dependency errors
- Each must be falsifiable with a stated prediction: "If X is the cause, then changing Y makes the bug disappear"
- No prediction = it's a vibe. Discard or sharpen it.
- Show the ranked list to the user before testing — cheap checkpoint, they often re-rank instantly. Don't block if they're AFK.

### 6. Probe for Data
- Prefer debugger/REPL inspection over logs where the env supports it — one breakpoint beats ten logs
- Tag every debug log with a unique prefix, e.g. `[DEBUG-a4f2]`, so cleanup is one grep
- Never "log everything and grep". Each probe maps to a specific hypothesis prediction
- Change one variable at a time

### 7. Fix Root Cause
- Keep fix minimal and focused
- Don't silence errors or add try/except to hide problems

### 8. Verify Fix
Run the loop from step 2 again — it must go green.

**If it still fails: loop back to step 2** — gather more debug data and try again.

Keep the minimised repro as a regression test, written at the seam that exercises the real bug pattern as it occurs at the call site. If no correct seam exists, that itself is the finding — report it rather than writing a test that gives false confidence.

### 9. Clean Up & Post-Mortem
- Remove debug scaffolding: `grep -r` the tag you chose in step 6 and delete every hit
- State the winning hypothesis in the commit/PR message so the next debugger learns

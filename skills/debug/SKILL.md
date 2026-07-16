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
A loop you can run, not a plan to read code.

**Pick a mechanism** — options are ordered by preference, pick the first that fits:
1. Failing test at the right seam (real code path, minimal mocking)
2. curl/HTTP script against a dev server
3. CLI invocation diffed against known-good output
4. Headless browser script (Playwright)
5. Replay a captured trace/payload
6. Throwaway minimal harness

**Then optionally wrap it in a strategy** — each needs a mechanism underneath to drive:
- Property/fuzz loop — for "sometimes wrong" bugs
- Bisection for regressions (`git bisect run` needs a script that exits non-zero on the bug)
- Differential loop — old vs new, or working vs broken input

### 3. Gate the Loop
Do not proceed until all four hold:
- **Red-capable** — asserts the user's exact symptom, not "didn't crash"
- **Deterministic** — pin time, seed RNG, freeze network
- **Fast** — seconds, not minutes
- **Agent-runnable** — you can name one command you have already run at least once

**Stop rule:** if you're reading code to build a theory before that command exists, stop.

**Exemption — non-deterministic bugs:** when the bug is inherently racy, **Deterministic** is relaxed to a reproduction-rate floor: the loop must go red in at least ~50% of repeated runs. The other three criteria still hold in full. Raise the rate by looping the trigger, parallelizing, and injecting sleeps into the code under test to widen the race window (this is fault injection, not waiting — the "never sleep, poll instead" rule does not apply). 50% flake is debuggable; 1% is not.

### 4. Prove Red, Then Minimize
Run the loop now and show the exact command plus its real failing output — never a claim that it fails. Confirm the failure **is the user's reported symptom**, not a nearby different error (import error, wrong fixture, unrelated assertion). Red for the wrong reason is not a repro — go back to step 2.

Only then shrink to the smallest scenario that still goes red for that same reason. Cut inputs/callers/config one at a time, re-running after each cut. Done when every remaining element is load-bearing. This shrinks the hypothesis space.

### 5. Rank Multiple Hypotheses
Generate 3-5 ranked hypotheses **before testing any** — single-hypothesis generation anchors on the first plausible idea.
- Generation prompts: logic errors (wrong algorithm/condition), type errors (wrong types passed/returned), edge cases (unhandled boundaries), import/dependency errors
- Each must be falsifiable with a stated prediction: "If X is the cause, then changing Y makes the bug disappear"
- No prediction = it's a vibe. Discard or sharpen it.
- Include the ranked list in your subagent return value. The calling agent surfaces it to the user, who may re-rank and re-invoke — cheap checkpoint. Never stall mid-run waiting for it.

### 6. Probe for Data
- Prefer debugger/REPL inspection over logs where the env supports it — one breakpoint beats ten logs
- If you do add debug logs, tag every one with a unique prefix, e.g. `[DEBUG-a4f2]`, so cleanup is one grep
- Never "log everything and grep". Each probe maps to a specific hypothesis prediction
- Change one variable at a time

### 7. Fix Root Cause
- Keep fix minimal and focused
- Don't silence errors or add try/except to hide problems

### 8. Verify Fix
Run the loop from step 2 again — it must go green.

**If it still fails: loop back to step 5** — the fix falsified your hypothesis, so re-rank and probe again.

Keep the minimized repro as a regression test, written at the seam that exercises the real bug pattern as it occurs at the call site. If no correct seam exists, that itself is the finding — report it rather than writing a test that gives false confidence.

### 9. Clean Up & Post-Mortem
- **Keep exactly one artifact: the minimized repro promoted to a regression test.** Everything else built along the way — curl scripts, throwaway harnesses, fuzz/bisection drivers, replay scripts, debug logs — is deleted. If the repro's mechanism isn't already a test, port it to one at the right seam, then delete the original.
- Cleanup pass: `grep -r` the tag from step 6 (if you added logs) and delete every hit, then delete the scaffolding files you created.
- State the winning hypothesis in the commit/PR message so the next debugger learns

---

*Portions of this workflow (the feedback-loop ladder and the loop gate) are adapted from Matt Pocock's `diagnosing-bugs` skill (github.com/mattpocock/skills), used under the MIT License.*

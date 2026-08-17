---
name: "stall-fallback"
description: "Detect a repeating background-agent stall bug and switch to sequential work. Use PROACTIVELY, without being asked, whenever a background/async subagent task-notification in the current session reports a failure matching 'Agent stalled: no progress for Ns (stream watchdog did not recover)' or the raw log form 'stall watchdog fired after 60000ms with no progress' — trigger on the 3rd such occurrence in the current session (i.e. more than twice), or on any occurrence in a session where 2+ have already happened."
---

## Step 1: Count

Track stall-watchdog failures seen in task-notifications this session (matching
`Agent stalled: no progress for Ns (stream watchdog did not recover)` or
`stall watchdog fired after 60000ms with no progress`).

Do nothing on the 1st or 2nd occurrence. On the 3rd, and every occurrence after
that, do Steps 2 and 3 below.

## Step 2: Explain to the user

Give a short, plain explanation (a few sentences, not a full report):

- This is a known, reproducible Claude Code bug — not a home-network problem.
  The user already ruled out their network with a full 1-hour clean
  connectivity monitor.
- It shows up most when 5+ background subagents run in parallel: background
  SSE streams go silently dead (zero further bytes) while the main
  interactive thread and its heartbeat stay healthy. This points at a
  connection-handling problem specific to concurrent background-agent
  streams (client pooling or server prioritization of interactive vs.
  background requests — root cause not confirmed).
- It also happens with a single background agent, so concurrency makes it
  worse or faster, but is not the only trigger.
- Filed as anthropics/claude-code#86499, referencing #54434, #25979, #53695,
  #55647, and anthropic-sdk-typescript#998.

## Step 3: Switch to sequential mode

For the rest of the current session, stop spawning further parallel or
background subagents (Agent tool or similar) for new work. Run all
remaining work directly and sequentially, in-line (Read/Edit/Bash/etc. done
directly, not delegated to background Task/Agent calls).

This applies within any role limits the user's global CLAUDE.md otherwise
sets (e.g. an orchestrator-must-delegate rule): here, "run it yourself"
means "one agent working sequentially" instead of "N agents working in
parallel" — never more parallel background agents while stalls are
recurring.

Stay in sequential mode until the user explicitly asks to resume parallel
background agent use (e.g. a new session, or saying so directly).

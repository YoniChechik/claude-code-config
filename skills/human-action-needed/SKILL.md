---
name: "human-action-needed"
description: "Use whenever a task might require a human-only action — approving an OAuth/app install, clicking a payment or install confirmation, revealing/copying a one-time credential, solving a CAPTCHA, or anything else Shopify/GCP/etc. structurally require a real logged-in human for. Do the entire task yourself first via Chrome MCP, right up to the blocked step, and only then ask — with the browser already sitting on the exact page, and the ask trimmed to the 1-2 clicks left."
---

# Human action needed

The point of this skill is to be thorough on your own behalf, not to save
yourself the trouble of asking. A step that *might* need a human is not a
reason to ask early — it's a reason to get as close to it as you possibly can
first, so that when you do ask, there is almost nothing left to do.

## Rules

1. **Run this on the main agent, never a dispatched subagent.** A subagent's
   browser tab and task state disappear when it finishes — only the main
   agent can leave a tab open, pause, and resume around a human's action in
   the same session.

2. **Try it yourself until you are fully, genuinely stuck — not before.**
   "This step looks like it needs a human" is not stuck. Actually attempt the
   click/navigation/command first. Stop only on a real, confirmed block:
   an explicit tool-safety classifier denial, or a documented structural
   human-only boundary (Shopify has no API to grant an app scopes on a
   merchant's behalf; a payment confirmation; a 2FA code sent to a personal
   device; a CAPTCHA). Don't guess that something is blocked — try it and see.

3. **Always navigate there yourself first, via Chrome MCP.** By the time you
   ask, the browser must already be sitting on the exact page the human needs
   — never make them find, search for, or type a URL themselves. Do every
   other safe step too (fill in what you can, select what you can, get the
   page into the state where literally one click/action is left).

4. **When you ask, be thorough about doing LESS, not more.** The message
   should contain only the 1-2 concrete actions still remaining — nothing
   about what you already did, no restated context. If you've done your job
   right there's rarely more than one click left.

5. **Every such ask MUST:**
   - **Open with an explicit mark** that this happens in the browser tab/page
     you already opened via Chrome MCP — e.g. "Do this in the tab I just
     opened" — never let it read as ambiguous about which window.
   - List only the remaining action(s), in order, as short imperative steps.
   - **End with:** "Say 'go' (or similar) once done and I'll continue from
     here." Never end with an open-ended question when the actual next step
     is this mechanical.

6. **On their "go," resume immediately** and finish the rest of the task
   without re-explaining or re-confirming what already happened.

## Example shape

> Do this in the tab I just opened (`dev.shopify.com/dashboard/.../apps/...`):
> 1. Click "Install app"
> 2. Confirm on the consent screen
>
> Say "go" once done and I'll continue from here.

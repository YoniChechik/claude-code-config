---
name: cr
description: Code-review gate for a PR the user hands over to check or push (e.g. "review and merge", "push PR N", a Linear ticket pointing at a PR). If the PR author is not the user, review it for security and good coding standards; if valid, squash-merge it and verify the deploy. Skip the merge for the user's own PRs.
---

# CR: review, then merge

1. `gh pr view <PR> --json author,mergeable,statusCheckRollup,files`. Compare the author to the current user (`gh api user -q .login`).
2. Own PR: do not run this review; follow the normal PR flow.
3. Not own PR: read the full diff. Check:
   - Security: authn/authz on new routes, secrets, injection, SSRF, unsafe deserialization, cost/abuse bounds, RLS and grants on new tables, PII and erasure.
   - Standards: repo AGENTS.md rules, no dead code or comments, tests for new behavior, additive-only API contract changes, no suppression increases.
4. Check CI with `gh api repos/<repo>/commits/<sha>/check-runs?filter=all`. Only expected author-gate failures (such as `pr-author-gates` for non-core authors) may be red.
5. Valid: `gh pr merge <PR> --squash`. If the only blocker is the author gate, the user must run the `--admin` merge (a hook blocks agents from it); hand them the exact command. Invalid: do not merge; list findings with file:line.
6. After merge, wait for the deploy and exercise the change on staging.

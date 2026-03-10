# Feature: CI Watcher Merge Conflict Detection

## TLDR
Add merge conflict detection to `ci_watch.sh` so it reports failure when a PR has conflicts, preventing the agent from telling the user "PR is ready for review and merge" when it actually has merge conflicts.

## Research and References
The GitHub CLI `gh pr view` command supports `--json mergeable,mergeStateStatus` fields. The `mergeable` field returns one of three `MergeableState` enum values: `MERGEABLE`, `CONFLICTING`, or `UNKNOWN`. The `UNKNOWN` state occurs when GitHub is still calculating mergeability (e.g., after a base branch update) and typically resolves within a few seconds. The `mergeStateStatus` field provides additional detail: `DIRTY` means conflicts, `CLEAN` means ready to merge, `BLOCKED` means checks/reviews required, `UNKNOWN` means still calculating, and `UNSTABLE` means checks failing.

There is a known issue (cli/cli#9583) where `mergeable` may not perfectly match the REST API's `mergeable_state`, but for our purposes detecting `CONFLICTING` is reliable. The `UNKNOWN` state requires a retry approach since GitHub computes mergeability asynchronously -- querying immediately after a push may return `UNKNOWN` before settling to `MERGEABLE` or `CONFLICTING`. A short polling loop (3-5 retries with the existing `POLL_INTERVAL`) handles this.

The check should run after CI completes (or after determining no CI exists) and also before reporting CI failures, since the agent needs to know about conflicts regardless of CI outcome. The merge conflict check needs the PR number for the branch, which can be obtained via `gh pr view $BRANCH --json mergeable,mergeStateStatus`. If no PR exists for the branch, the check should be skipped (push without PR).

References:
- [gh pr view manual](https://cli.github.com/manual/gh_pr_view)
- [MergeableState enum values discussion](https://github.com/cli/cli/discussions/8020)
- [gh pr view mergeable output issue](https://github.com/cli/cli/issues/9583)
- [GitHub GraphQL enums docs](https://docs.github.com/en/graphql/reference/enums)

### Task 1: Add merge conflict check function to ci_watch.sh
**What:**
- Add a `check_merge_conflicts` function that runs `gh pr view "$BRANCH" --json mergeable,mergeStateStatus` and parses the result
- Handle the `UNKNOWN` state with a retry loop (up to 5 retries, reusing `POLL_INTERVAL` sleep) since GitHub computes mergeability asynchronously after pushes
- If no PR exists for the branch (`gh pr view` fails), skip the check and return success
- Return exit code 1 if `mergeable == "CONFLICTING"`, exit code 0 otherwise
- Output a clear actionable message on conflict: "PR on branch '$BRANCH' has merge conflicts. You MUST resolve the merge conflicts now before continuing."

### Task 2: Integrate merge conflict check into all exit paths
**What:**
- Call `check_merge_conflicts` before the "CI passed" exit on line 56 (all workflows green). If conflicts detected, exit 1 with the conflict message instead of reporting success
- Call `check_merge_conflicts` before the "No CI workflows found" exit on line 22. If conflicts detected, exit 1 with the conflict message instead of silently passing
- Call `check_merge_conflicts` in the CI failure path (after line 66) -- append conflict info to the failure message if both CI failed AND there are conflicts, so the agent knows about both problems
- Call `check_merge_conflicts` before the timeout exit on line 88 -- append conflict info if present

### Task 3: Add tests for merge conflict detection
**What:**
- Create `tests/test_ci_watch_merge_conflicts.bats` using the [bats-core](https://github.com/bats-core/bats-core) framework (install via `brew install bats-core` if needed)
- Mock `gh pr view` to return `CONFLICTING`, `MERGEABLE`, and `UNKNOWN` states
- Mock `gh run list` to simulate various CI scenarios (no runs, passing runs, failing runs)
- Mock `git rev-parse` to return a fixed SHA
- Test cases:
  - CI passes + no conflicts = exit 0 with success message
  - CI passes + conflicts = exit 1 with conflict message
  - No CI workflows + no conflicts = exit 0
  - No CI workflows + conflicts = exit 1 with conflict message
  - CI fails + conflicts = exit 1 with both CI failure AND conflict info in message
  - `mergeable == UNKNOWN` retries then resolves to `CONFLICTING` = exit 1
  - `mergeable == UNKNOWN` retries then resolves to `MERGEABLE` = exit 0
  - No PR exists for branch (gh pr view fails) = skip conflict check, behave as before
  - CI timeout + conflicts = exit 1 with both timeout AND conflict info

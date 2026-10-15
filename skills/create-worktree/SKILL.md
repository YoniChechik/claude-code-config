---
name: "create-worktree"
description: "Create isolated git worktree for feature"
argument-hint: "[feature-description]"
---

Creates a git worktree for isolated feature development. Handles new features, existing local branches, and existing remote branches.

## Feature description from user input
"$ARGUMENTS"

### Feature Description Validation
  - If empty or missing: "Error: Feature description is required. Please provide a detailed description."

## Process

### Step 1: Parse Feature Description
- Check whether the description names a Linear ticket (a `linear.app/.../issue/TEAM-123` URL, or a bare `TEAM-123`-style id).
  - If so, call `mcp__linear__get_issue` for that issue and read its `gitBranchName` field. On success, use it as the feature name instead of deriving one from the description — this keeps the branch in the exact shape Linear's GitHub integration expects, so pushing/opening a PR from it auto-transitions the ticket to "In Progress" and assigns it to the pushing user's git identity.
  - If no ticket is named, or the lookup fails, fall through to the description-based naming below.
- Decide on feature name based on description (fallback, or when no Linear ticket applies)
- Convert feature name to kebab-case for branch naming
- Feature name must NOT contain `/`. If the chosen name has a prefix like `feat/`, `fix/`, `chore/`, etc. (this also covers Linear's own team-prefixed `gitBranchName`, e.g. `yoni/paper-179-...`), strip everything up to and including the last `/` (e.g. `feat/add-login` → `add-login`, `yoni/paper-179-change-app-access` → `paper-179-change-app-access`). The final name must be a flat kebab-case string with no slashes.

### Step 2: Run the worktree script
Run `create_worktree.sh` from this skill's own directory — the "Base directory for this skill" path given above, not a hardcoded `~/.claude` path, since this file is shared verbatim across tools with different config-directory names:
```bash
bash "<skill-base-dir>/create_worktree.sh" "$FEATURE_NAME"
```
Substitute `<skill-base-dir>` with the literal base-directory path given above.

This handles: fetching latest main from origin, branch detection (new / existing local / existing remote), `git worktree add` at `.claude/worktrees/$FEATURE_NAME`, branching off `origin/main` (never a stale local main), env symlinking, and environment setup. It does not set the workspace title — that happens in Step 3 below.

The branch keeps the exact name Linear gave it, but the worktree DIRECTORY name is capped at 58 characters: devtrees builds its unix socket path from the directory name, and macOS rejects socket paths over 103 bytes, so a longer directory name can never boot (`SOCKET_PATH_TOO_LONG`) and `DEVTREES_RUNTIME_DIR` cannot help. A longer name is truncated to its leading characters plus `-` and an 8-hex hash of the full name (no trailing `-`), so the ticket-id prefix stays readable and distinct names stay distinct. Names of 58 characters or fewer are used unchanged.

The script prints the worktree path (relative to the repo root) as its last stdout line. That printed path, not `$FEATURE_NAME`, is the worktree location: use it in Steps 4 and 5. `destroy_worktree.sh` accepts the branch name, the directory name or the path.

### Step 3: Set the session name
Invoke the `/session-name` skill, passing the already-derived kebab-case `$FEATURE_NAME` as its argument (`/session-name $FEATURE_NAME`). See that skill for exactly what it does — it stores the name and, where the current tool supports it, propagates it to the terminal/workspace title too.

### Step 4: Notify User
Tell user:
- The worktree has been created at the path the script printed (`.claude/worktrees/<dir-name>`)
- The branch `$FEATURE_NAME` is tracking remote
- The session is renamed to `$FEATURE_NAME` via `/session-name`.

### Step 5: Change to Feature Directory
Change to the feature worktree directory:
```bash
cd "$(git rev-parse --show-toplevel)/<printed worktree path>"
```
Confirm with `pwd`. A known limitation: this cannot change directory out of the base directory where the session started, if the harness restricts that.

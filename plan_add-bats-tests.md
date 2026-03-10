# Feature: Add BATS Tests for Shell Scripts

## TLDR
Add BATS test coverage for 6 shell scripts (4 high priority, 2 medium priority) following the existing test patterns established in `test_ci_watch_merge_conflicts.bats`. Each script gets its own test file with PATH-based mocking, temp directory isolation, and comprehensive scenario coverage.

## Research and References

The project already has a solid BATS testing pattern in `tests/test_ci_watch_merge_conflicts.bats` that uses PATH-based mocking (creating mock executables in a temp dir prepended to PATH). This is the recommended approach for BATS testing per [bats-core documentation](https://bats-core.readthedocs.io/en/stable/writing-tests.html) and [community best practices](https://peerdh.com/blogs/programming-insights/creating-a-framework-for-mocking-external-commands-in-bash-unit-tests). The existing pattern avoids the `bats-mock` library in favor of hand-written mock scripts controlled by environment variables, which is simpler and sufficient for this codebase. All scripts under test read stdin or take arguments, call external commands (git, gh, jq, find), and produce stdout/exit codes -- making them straightforward to test with this approach.

Key patterns to follow from the existing test:
- `setup()` creates `MOCK_BIN` temp dir, writes mock scripts, prepends to PATH
- `teardown()` removes `MOCK_BIN` with `rm -rf`
- Environment variables control mock behavior (e.g., `MOCK_MERGEABLE`)
- Tests use `run`, then assert on `$status` and `$output`
- Scripts that need patching (e.g., timing constants) use `sed` to create a patched copy

Scripts that read from stdin (hooks receiving JSON) need their input piped or provided via `<<<` within the `run` command. The `run` keyword in BATS does not support stdin piping directly, so the pattern is: create a wrapper script that feeds stdin to the target script, then `run` the wrapper.

---

### Task 1: Test pre_tool_use__base_dir_protect.sh (security-critical)
**What:**
- Create `tests/test_pre_tool_use__base_dir_protect.bats`
- Mock `jq` by symlinking real jq (same as existing test pattern)
- The script reads JSON from stdin, so create a helper function that writes a wrapper script to pipe JSON into the target script, then `run` the wrapper
- No need to mock `git` for most cases -- only the `is_in_git_repo` function matters, which checks for `.git` directories. Create real temp directory structures with/without `.git` dirs

**Test cases (Bash tool_name):**
- `git add` command with cwd inside `_clones/` -> exit 0 (allowed)
- `git commit` command with cwd outside `_clones/` -> outputs permissionDecision=ask JSON
- `git push` command outside `_clones/` -> outputs permissionDecision=ask JSON
- Non-git bash command (e.g., `ls`) outside `_clones/` -> exit 0 (allowed, not a git write)
- Empty command -> exit 0
- All git write patterns: add, stage, commit, checkout, switch, push, stash, reset, rebase, merge, cherry-pick, mv, rm, clean, `branch -d` -> verify detection
- `git log` (read-only) outside `_clones/` -> exit 0 (not blocked)
- `git status` (read-only) outside `_clones/` -> exit 0

**Test cases (Edit/Write/NotebookEdit tool_name):**
- File path inside `_clones/` dir (with `.git` ancestor) -> exit 0 (allowed)
- File path outside `_clones/` but inside a git repo (has `.git` ancestor) -> outputs permissionDecision=ask JSON
- File path outside any git repo (no `.git` ancestor) -> exit 0 (allowed)
- Empty file_path -> exit 0

**Setup notes:**
- Create temp dir structures: one with `_clones/project/.git/`, one with just `.git/`, one with no `.git`
- Feed JSON via stdin wrapper pattern

---

### Task 2: Test session_start.sh (complex startup logic)
**What:**
- Create `tests/test_session_start.bats`
- Mock: `git`, `jq` (symlink real), `rm`
- This script always exits 0 and outputs JSON with a `systemMessage` field
- Use environment variables to control git mock behavior

**Test cases (environment validation):**
- jq missing -> output contains "jq is not installed"
- Not a git repo (git rev-parse fails) -> output contains "not a git repository"
- Both ok -> output contains "Environment: OK"

**Test cases (git sync):**
- `git merge --ff-only` succeeds with "Already up to date" -> output contains "Git: up to date"
- `git merge --ff-only` succeeds with actual merge -> output contains "Git: merged"
- `git merge --ff-only` fails -> output contains "Git: error:"
- No remote tracking branch -> output contains "Git: up to date"
- Detached HEAD (no current branch) -> output contains "Git: no current branch"

**Test cases (clone cleanup):**
- Clone dir with branch that exists on remote -> kept (output contains "Existing:")
- Clone dir with branch on main/master -> kept (output contains "Existing:")
- Clone dir with branch not on remote -> removed (output contains "Removed:")
- No `_clones` dir -> no clone section in output

**Test cases (branch cleanup):**
- Branch with `: gone]` tracking -> removed (output contains "Removed branch:")
- Current branch (starts with `*`) -> skipped
- main/master branches -> skipped

**Test cases (output format):**
- Output is valid JSON with `systemMessage` key
- Always exits 0 regardless of errors

**Setup notes:**
- Mock `git` with env-var-controlled behavior for each subcommand (rev-parse, fetch, branch, merge, ls-remote, branch -D, symbolic-ref)
- Create temp `_clones/` dir structure with fake clone dirs containing `.git/` dirs
- Mock `jq` by symlinking real jq for JSON output formatting
- For the "jq missing" test: override PATH to exclude real jq, provide a failing mock

---

### Task 3: Test symlink_env_files.sh (file operations)
**What:**
- Create `tests/test_symlink_env_files.bats`
- No external command mocking needed -- this script uses `find`, `ln`, `mkdir` which should run against real temp dirs
- Create real temp directory structures as source and target

**Test cases:**
- Source dir with `.env` file -> symlink created in target
- Source dir with `.env.local` file -> symlink created
- Source dir with `.env.example` file -> excluded (not symlinked)
- Source dir with `.env.tpl` file -> excluded
- Source dir with `.env` in `node_modules/` -> excluded (pruned)
- Source dir with `.env` in `.git/` -> excluded (pruned)
- Source dir with `.env` in `venv/` and `.venv/` -> excluded (pruned)
- Source dir with `.env` in `_clones/` -> excluded (pruned)
- Nested `.env` file (e.g., `sub/dir/.env.production`) -> symlink with correct relative path, parent dirs created
- No `.env` files found -> exit 0, output "No .env* files found"
- Missing source_dir argument -> exit 1
- Missing target_dir argument -> exit 1
- Target already has existing file at path -> replaced with symlink
- Target already has existing symlink at path -> replaced with new symlink

**Setup notes:**
- Create real temp source dir with various `.env*` files and excluded dirs
- Create real temp target dir
- Verify symlinks with `readlink` and `test -L`

---

### Task 4: Test setup_project_env.sh (project detection)
**What:**
- Create `tests/test_setup_project_env.bats`
- Mock `uv` and `npm` (they should not actually run, just record that they were called)
- Script uses `set -e` so mocks must exit 0

**Test cases:**
- `pyproject.toml` exists -> runs `uv venv`, output contains "Detected Python project"
- `package-lock.json` exists -> runs `npm install`, output contains "Detected npm project"
- Both files exist -> runs both commands
- Neither file exists -> silent exit 0, no output about detection
- Only `pyproject.toml` -> `npm` mock is NOT called
- Only `package-lock.json` -> `uv` mock is NOT called

**Setup notes:**
- Create temp working dir, `cd` into it before running script
- Mock `uv` and `npm` as scripts that write to a marker file (e.g., `$MOCK_BIN/uv_called`) so tests can verify they were invoked
- The script checks files relative to cwd, so `run bash -c "cd $TEMP_DIR && $SCRIPT_PATH"` pattern

---

### Task 5: Test git_branch_state.sh (JSON output)
**What:**
- Create `tests/test_git_branch_state.bats`
- Mock `git` with env-var-controlled responses
- Symlink real `jq` for JSON construction

**Test cases:**
- Normal branch with no divergence, 0 behind main -> `{"branch":"feat","diverged":false,"behind_main":0}`
- Branch diverged from origin (both local_only and remote_only > 0) -> `diverged: true`
- Branch behind main by N commits -> `behind_main: N`
- Not inside git work tree -> exit 0, no output
- No origin remote -> exit 0, no output
- Detached HEAD (symbolic-ref fails) -> exit 0, no output
- No remote tracking branch (origin/branch doesn't exist) -> diverged: false
- Output is valid JSON (pipe through jq)

**Setup notes:**
- Mock `git` to handle: `rev-parse --is-inside-work-tree`, `remote`, `symbolic-ref --short HEAD`, `rev-parse --verify`, `rev-list --count`
- Use `MOCK_BRANCH`, `MOCK_LOCAL_ONLY`, `MOCK_REMOTE_ONLY`, `MOCK_BEHIND_MAIN` env vars

---

### Task 6: Test post_tool_use__ci_push.sh (hook detection)
**What:**
- Create `tests/test_post_tool_use__ci_push.bats`
- Mock `git`, `gh`, `jq` (symlink real)
- Script reads JSON from stdin (same wrapper pattern as Task 1)
- Script uses `set -euo pipefail` and redirects stdout/stderr internally

**Test cases:**
- Command contains `git push` + PR exists + CI runs exist -> outputs hookSpecificOutput JSON with additionalContext
- Command contains `gh pr create` + PR exists + CI runs exist -> outputs hookSpecificOutput JSON
- Command does NOT contain git push or gh pr create -> exit 0, no output
- Command contains `git push` but no PR exists (gh pr view fails) -> exit 0, no output
- Command contains `git push` + PR exists but no CI runs -> exit 0, no output
- Output JSON contains correct branch name
- Output JSON contains path to ci_watch.sh

**Setup notes:**
- Mock `git rev-parse --abbrev-ref HEAD` to return a branch name
- Mock `gh pr view` to succeed or fail based on env var
- Mock `gh run list` to return empty array or array with entries
- Stdin wrapper to pipe JSON `{"tool_input":{"command":"git push origin main"}}`

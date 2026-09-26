---
name: "worktree-lifecycle"
description: "Create and fully tear down git worktrees safely — anchored on the true main repo root (never nested), with a real teardown that frees the disk space a worktree's dependency install costs."
argument-hint: "setup <feature-name> | destroy <name-or-path> [--force] [--delete-branch]"
---

## Why this exists

Two real incidents drove this skill:

1. **Nested worktrees.** The older `create-worktree` skill's script resolves
   the repo root with `git rev-parse --show-toplevel`. Run from inside a
   worktree instead of the main repo checkout, that returns the WORKTREE's
   own top level, not the main repo's — so the new worktree gets created
   nested inside the old one (e.g.
   `core/.claude/worktrees/A/.claude/worktrees/B`). This repo's automated
   worktree/branch sweep hook (`session-maintenance.sh`, see the root
   `AGENTS.md` / `vibe-code-onboarding/AGENTS.md`) treats a nested worktree
   as orphaned and **destroys it without warning** — including any
   uncommitted work inside it.
2. **No teardown.** A worktree's setup runs a full dependency install
   (`pnpm install` across every workspace project, or `uv venv`), which costs
   several GB of disk per worktree. There was a creation script but nothing
   to fully remove one afterward, so finished worktrees piled up until the
   disk filled ("No space left on device"), blocking new worktree creation
   entirely.

## Hard rules

- **Never run `git worktree add` / `git worktree remove` directly**, and
  **never use Claude Code's built-in `EnterWorktree`/`ExitWorktree` tools**
  for a repo worktree. Always go through `setup_worktree.sh` /
  `destroy_worktree.sh` (or the existing `/create-worktree` skill for
  creation, which this skill's setup script is interoperable with — both
  produce a worktree at the same `<main-repo-root>/.claude/worktrees/<name>`
  convention).
- **Never create a worktree nested inside another worktree's directory.**
  `setup_worktree.sh` hard-fails if this would happen — do not work around
  that failure by passing a different path; instead run it from the actual
  main repo checkout.
- **Every script call uses absolute paths, never a bare `cd` you expect to
  persist.** An agent's Bash tool resets cwd between calls, and the whole
  point of these scripts is to work correctly regardless of the caller's
  cwd anyway (see "How the anti-nesting fix works" below).

## When to use which script

- **`setup_worktree.sh <feature-name>`** — creating a new worktree for a
  feature, fix, or scratch task. Use this (or `/create-worktree`, which
  wraps the same convention) any time you need an isolated branch + working
  directory. `<feature-name>` must be a flat kebab-case string (no slashes).
- **`destroy_worktree.sh <name-or-path> [--force] [--delete-branch]`** —
  tearing a worktree down once its work has landed (merged PR), been
  abandoned, or was scratch work no longer needed. Run this as soon as a
  worktree is done — don't let finished worktrees accumulate; each one is
  several GB of `node_modules`/`.venv` sitting on disk doing nothing.

## How the anti-nesting fix works

`setup_worktree.sh` resolves the main repo root via
`git rev-parse --git-common-dir` (the parent of that path), not
`--show-toplevel` — `--git-common-dir` always points at the main repo's real
`.git` directory even when invoked from inside a linked worktree, so the new
worktree always lands at `<true-main-repo-root>/.claude/worktrees/<name>`
regardless of the caller's cwd. As a second, explicit belt-and-suspenders
check, it also cross-references the intended target path against every
already-registered worktree from `git worktree list --porcelain` and hard-
fails if the target (or the resolved main repo root itself) would sit inside
a different worktree.

## Usage

Run each script from this skill's own directory — the "Base directory for
this skill" path given above:

```bash
# Create a worktree for a new feature/fix (branches off origin/main; attaches
# to an existing local/remote branch if the name already exists as one).
bash "<skill-base-dir>/setup_worktree.sh" my-feature-name

# Tear one down once its work has landed. Refuses (prints exactly what would
# be lost) if the branch has uncommitted changes or unpushed commits.
bash "<skill-base-dir>/destroy_worktree.sh" my-feature-name

# Force through the safety check (irreversible — only when the work is
# genuinely disposable).
bash "<skill-base-dir>/destroy_worktree.sh" my-feature-name --force

# Also delete the local branch once the worktree is gone (default: keep the
# branch, so the commit history stays easily recoverable/re-checkoutable).
bash "<skill-base-dir>/destroy_worktree.sh" my-feature-name --delete-branch
```

`destroy_worktree.sh` accepts either a bare feature name (resolved against
`<main-repo-root>/.claude/worktrees/<name>`) or a full path to a registered
worktree. Both scripts work from any cwd inside the repo (main checkout or
any worktree) — they always resolve the true main repo root themselves.

`setup_worktree.sh` preserves the existing `create-worktree` skill's
behavior: branch detection (new feature vs. existing local branch vs.
existing remote branch), branching off freshly-fetched `origin/main` (never
a stale local main), `.env*` symlinking from the main repo, and running the
project's install step (`pnpm install` / `npm install` / `uv venv`) so the
new worktree is actually usable.

`destroy_worktree.sh` runs `git worktree remove --force`, then `rm -rf`s the
directory as a belt-and-suspenders guarantee (in case anything untracked —
`node_modules`, `.venv`, build output — was left behind), then
`git worktree prune`s stale administrative metadata. It reports what was
removed (path, branch, whether the branch was also deleted) and the disk
space freed.

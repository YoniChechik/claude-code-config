# Claude Code Config

Personal Claude Code configuration (hooks, commands, agents, settings).

## Installation

**Prerequisites:**

- Claude Code installed (creates `~/.claude` on first run).
- [`uv`](https://docs.astral.sh/uv/) — runs `ruff` for the post-edit lint hook and the setup cleanup step.
- [`jq`](https://jqlang.org/) — every hook reads its JSON input with it.
- [`shfmt`](https://github.com/mvdan/sh) — parses Bash commands for the hooks (`scripts/bashparse`). `setup.sh` installs it with Homebrew; without Homebrew, install it by hand.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YoniChechik/claude-code-config/main/setup.sh)
```

This git-enables your existing `~/.claude` directory, removes the retired webhook MCP registration, and installs `shfmt`:

- **Already installed:** it prints the version and moves on.
- **Homebrew present:** it runs `brew install shfmt`. If that fails, it prints a warning and finishes the rest of setup.
- **No Homebrew:** it prints where to download `shfmt` and finishes the rest of setup.

Until `shfmt` is on the `PATH`, the PreToolUse guards ask before every Bash command and the PostToolUse Bash hooks skip.

## What it does

- **Sound notifications:** Hooks that play sounds when Claude needs attention.

## Hook Bash parsing

`scripts/_bashparse.sh` (CLI: `scripts/bashparse [--cwd DIR] [--depth N] < command`) turns one Bash command line into a flat JSON array of segments, one per simple command, using `shfmt --to-json` and `scripts/bashparse.jq`.

**Failure contract.** `bp_parse` returns non-zero and sets `BP_ERR` when it cannot give a trustworthy answer. A guard must treat every non-zero return as ask or deny, never allow.

| Return | Meaning |
| --- | --- |
| 2 | Bash syntax error (zsh-only syntax, unterminated quote) |
| 3 | `shfmt` not installed |
| 4 | the parse pipeline exceeded `BASHPARSE_TIMEOUT` seconds (default 3); its whole process group is killed |
| 5 | `jq` missing or failed, or `shfmt` produced bad JSON |
| 6 | `bp_parse_hook` got hook input that is not a JSON object, or whose `tool_input.command` or `cwd` is not a string or contains a NUL byte |

**Fields callers must respect.**

- `argv` is the decoded word array after wrappers (`rtk`, `env`, `command`, `sudo`, `timeout`, ...) are removed. Guards match on `argv`, never on joined text. `dynamic[i]` is true when word `i` depends on expansion, globbing or substitution; its text holds `\uFFFD` for the dynamic part. A variable assigned once in the same command by a standalone `NAME=literal` (never re-assigned, read, looped over, exported, declared or used with `${NAME:-...}`-style operators) expands to its value at every use that follows it on the same control path, so `S=/tmp/x; $S/run.sh` has `argv[0]` `/tmp/x/run.sh`, and an unquoted value with spaces splits into words. `bp_segments_text` is for display only.
- `writes` lists the static paths a segment writes: write redirects (`>`, `>>`, `&>`, `>|`, `<>`, `>&file`, including ones on an enclosing compound command, already absolute), `tee` files, `rm`/`rmdir`/`touch`/`mkdir`/`unlink`/`shred`/`truncate` operands, `chmod`/`chown`/`chgrp` files, `mv` sources and destination, the `cp`/`ln`/`install`/`rsync` destination, `sed -i` and `perl -i` files, and `dd of=`. Relative entries are relative to `cwd_alts`. Dynamic targets are left out.
- `unknown: true` (with `unknown_reasons`) means the parser cannot see what will run. Reasons: `dynamic command name`, `substitution as command`, `source`, `dynamic eval`, `dynamic shell code`, `dynamic shell heredoc`, `shell reads stdin`, `indirect exec` (`xargs`, `parallel`, `find -exec`), `env -S`, `depth limit` (code nested deeper than `BASHPARSE_DEPTH`, default 4), `nested parse error`.
- Static nested code is parsed, not marked unknown: `bash|sh|zsh -c '...'`, `eval` with static words, and a heredoc or here-string fed to a shell. Its segments follow the parent with `parent`, `depth` and `via`.
- `cwd_alts` lists every directory the segment can run in when that set is finite (`cd /w; cmd` gives the session directory and `/w`); it is empty when the directory is unknowable (dynamic `cd`, `pushd`, `source`, `eval`, `env -C`). `git.cwd_alts` is the same after `git -C`. A guard may allow a write only when every entry is safe.
- `cwd_known: false` means the shell's directory is not certain: after a `cd` that might have failed (`cd x; cmd`), after an `if`, `||` or loop that contains a `cd`, `cd -`, `cd` with `CDPATH` set, `pushd`/`popd`, `source`, `eval`, a dynamic `cd` target, or a call to a function defined in the same command. `cd x && cmd` and `cd x || exit` keep it known, and so does any `cd` to an absolute path. `git.cwd`/`git.cwd_known` add `git -C` on top; stacked relative `-C`, `--git-dir`, `--work-tree` and `GIT_DIR`/`GIT_WORK_TREE` make it unknown. **Unknown cwd plus a write means deny or ask.**
- `exit_code_belongs_to_command` is true only when a zero exit status for the whole Bash call proves this segment ran and succeeded. It is false for non-last pipeline members (no `pipefail` assumed), negated (`!`) or backgrounded commands, the left side of `&&`, either side of `||`, anything before a later `;`, and anything inside a substitution, function or compound command. When it is false, callers need other evidence, such as a PR URL in the output.
- Heredoc bodies are data. Only `$(...)` inside an unquoted body runs, and it appears as an `in_substitution` segment.
- `git.config` lists the values of `-c` and `--config-env`; a dynamic value appears as `\uFFFD`.

**Bash API.** One `jq` process does the whole flattening: `_bashparse.sh` pipes the hook JSON and `shfmt`'s AST into `bashparse.jq`, which also emits a NUL-separated record per segment. After `bp_parse` or `bp_parse_hook`, `BP_N` is the segment count and `bp_seg <i>` loads segment `i` into `SEG_*` variables and arrays (`SEG_ARGV`, `SEG_DYN` as a `0`/`1` string, `SEG_ENV`, `SEG_RAW`, `SEG_REASONS`, `SEG_WRITES`, `SEG_CWD`, `SEG_CWD_KNOWN`, `SEG_CWD_ALTS`, `SEG_FLAGS`, `SEG_GIT_*`) with no further process. `SEG_FLAGS` letters: `S` subshell, `G` brace group, `X` substitution, `F` function body, `C` compound command, `B` background, `N` negated, `A` exit code attributable, `U` unknown, `P` nested code. `bp_find [--all] word...` matches unwrapped argv prefixes (git options normalized) into `BP_MATCHES`. `bp_hook_prepare` parses a hook payload once and is a no-op when `BP_READY=1`, which is how `pre_tool_use__dispatch.sh` hands one parse to both guards.

**How the hooks use it.**

Every guard decision and skipped real candidate is one line in `${CLAUDE_HOOK_LOG_DIR:-~/.claude/logs}/hooks.log`. The PostToolUse hooks log nothing for a command that is not a candidate: the cheap substring filter, a non-Bash tool and a parse that finds no `git push`, `gh pr create` or `gh pr merge` all exit silently.

- `pre_tool_use__dispatch.sh` parses once and runs both guards on that parse. Both guards fail open: they prompt only on something they positively detect. Non-Bash tools skip the parse, so a missing `shfmt` never blocks an `Edit`.
- `pre_tool_use__permission_guard.sh` and `pre_tool_use__base_dir_protect.sh` match argv, so quoted text and quoted heredoc bodies are never commands. The permission guard asks about an `unknown` segment or an unparseable command only when the command text names a guarded tool (`gh`, `gcloud`, `bq`, `curl`, `wget`, `http`, `xh`, `supabase`, `pulumi`).
- The base-dir guard ignores unknown segments and unparseable commands. It denies a `writes` path that resolves into a git repo outside `.claude/worktrees/` (gitignored paths and `projects/*/memory/` excepted), and asks when only some `cwd_alts` candidates do. For git it denies a write in a subshell, substitution, function or nested shell, denies `--git-dir`/`--work-tree`, allows a write only when every `cwd_alts` entry is a worktree, and asks when some candidate is not.
- `post_tool_use__gh_monitor_trigger.sh` finds `git push`, `gh pr create` and `gh pr merge` anywhere in a compound command. When `A` is not set it needs evidence: `HEAD == @{push}` for a push, a PR URL in the output for a create, PR state `MERGED` for a merge (always). Every skipped candidate writes one `skip:` line, and duplicate watchers for the same branch collapse into one.
- `post_tool_use__sync_main_after_merge.sh` syncs only after a parsed `gh pr merge`, from that segment's directory.

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
| 4 | `shfmt` or `jq` exceeded `BASHPARSE_TIMEOUT` seconds (default 3) |
| 5 | `jq` missing or failed, or `shfmt` produced bad JSON |
| 6 | `bp_parse_hook` got hook input that is not JSON or has no `tool_input.command` |

**Fields callers must respect.**

- `argv` is the decoded word array after wrappers (`rtk`, `env`, `command`, `sudo`, `timeout`, ...) are removed. Guards match on `argv`, never on joined text. `dynamic[i]` is true when word `i` depends on expansion, globbing or substitution; its text holds `\uFFFD` for the dynamic part. `bp_segments_text` is for display only.
- `unknown: true` (with `unknown_reasons`) means the parser cannot see what will run. Callers must treat it conservatively. Reasons: `dynamic command name`, `substitution as command`, `source`, `dynamic eval`, `dynamic shell code`, `dynamic shell heredoc`, `shell reads stdin`, `indirect exec` (`xargs`, `parallel`, `find -exec`), `env -S`, `depth limit` (code nested deeper than `BASHPARSE_DEPTH`, default 4), `nested parse error`.
- Static nested code is parsed, not marked unknown: `bash|sh|zsh -c '...'`, `eval` with static words, and a heredoc or here-string fed to a shell. Its segments follow the parent with `parent`, `depth` and `via`.
- `cwd_known: false` means the shell's directory is not certain: after a `cd` that might have failed (`cd x; cmd`), after an `if`, `||` or loop that contains a `cd`, `cd -`, `cd` with `CDPATH` set, `pushd`/`popd`, `source`, `eval`, a dynamic `cd` target, or a call to a function defined in the same command. `cd x && cmd` and `cd x || exit` keep it known. `git.cwd`/`git.cwd_known` add `git -C` on top; stacked relative `-C`, `--git-dir`, `--work-tree` and `GIT_DIR`/`GIT_WORK_TREE` make it unknown. **Unknown cwd plus a write means deny or ask.**
- `exit_code_belongs_to_command` is true only when a zero exit status for the whole Bash call proves this segment ran and succeeded. It is false for non-last pipeline members (no `pipefail` assumed), negated (`!`) or backgrounded commands, the left side of `&&`, either side of `||`, anything before a later `;`, and anything inside a substitution, function or compound command. When it is false, callers need other evidence, such as a PR URL in the output.
- Heredoc bodies are data. Only `$(...)` inside an unquoted body runs, and it appears as an `in_substitution` segment.

# Claude Code Config

Personal Claude Code configuration (hooks, commands, agents, settings).

## Installation

**Note:** This assumes your `~/.claude` directory already exists (created by Claude Code on first run).

```bash
git clone https://github.com/YoniChechik/claude-code-config.git /tmp/claude-temp
mv /tmp/claude-temp/.git ~/.claude/ && cd ~/.claude && git reset --hard HEAD
rm -rf /tmp/claude-temp
```

### Why this installation method?

This approach "git-enables" your existing Claude Code config directory instead of replacing it:

1. **Claude Code auto-creates `~/.claude`** - On first run, Claude Code creates this directory with default configuration files
2. **Preserves directory structure** - Moving only the `.git` folder keeps the existing directory intact, avoiding disruption to active sessions
3. **Non-destructive** - `git reset --hard HEAD` overwrites files with repo versions while keeping the directory structure and any uncommitted local changes discoverable
4. **Alternative would be destructive** - Doing `rm -rf ~/.claude && git clone ...` would lose active sessions and make clean updates harder

This makes your config trackable and syncable across machines while keeping Claude Code running smoothly.

### Optional: Short alias

```bash
# Add to ~/.bashrc or ~/.zshrc
alias cc="claude"
```


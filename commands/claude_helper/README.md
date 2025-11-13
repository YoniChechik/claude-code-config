# Claude Helper Commands

Quick reference commands for Claude Helper HTTP API.

## Available Commands

- **[ping](./ping.md)** - Show notification with message
- **[setTerminalTitle](./setTerminalTitle.md)** - Rename terminal with tracking
- **[compareReferences](./compareReferences.md)** - Compare two git references
- **[compareHead](./compareHead.md)** - Compare HEAD with reference
- **[clearComparisons](./clearComparisons.md)** - Clear GitLens comparisons

## Usage

Each command file contains a one-line executable curl command.

Commands prefixed with `!` can be executed directly by Claude Code.

## Environment Variables

- `$CLAUDE_HELPER_CURRENT_TERMINAL_TITLE` - Current terminal's unique title (set in Claude Helper terminals)
- `$CLAUDE_HELPER_PORT` - HTTP port for sending commands (automatically assigned, starting from 3456)

## API Endpoint

All commands use: `http://localhost:$CLAUDE_HELPER_PORT`

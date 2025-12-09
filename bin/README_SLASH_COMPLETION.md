# Slash Command Completion

Fuzzy search and inline completion for slash commands in the `cc` REPL.

## Features

- **Inline suggestions** as you type (shown in gray)
- **Fuzzy matching** - matches substrings anywhere in command names
- **Arrow key navigation** - cycle through matching commands
- **Tab or Enter** to accept suggestion
- **Backspace** past `/` to cancel

## Usage

When using the `cc` REPL, simply type `/` at the start of your input:

```bash
> /as_        # Shows: /ask in gray
> /pr_        # Shows: /pr-comments in gray (use arrows to cycle)
> /new_       # Shows: /new-feature in gray
```

### Controls

- **Type `/`** - Start slash completion
- **Type more characters** - Narrow down matches
- **Left/Right arrows** - Cycle through matching commands
- **Tab or Enter** - Accept current suggestion
- **Backspace** past `/` - Cancel completion

## How It Works

### Command Discovery

Commands are discovered from `~/.claude/commands/*.md` files. The command name is the filename without the `.md` extension.

### Fuzzy Matching

The fuzzy matcher uses simple substring matching (case insensitive). Commands are scored and sorted:

1. **Exact match** - score 0
2. **Prefix match** - score 1
3. **Substring match** - score 100 + position

### Inline Rendering

As you type, the best matching command is shown inline in gray (ANSI color code `\033[90m`). The terminal is switched to raw mode to capture individual keystrokes and render suggestions in real-time.

## Files

- **`slash_complete.sh`** - Core fuzzy matching and command discovery
- **`cc_readline.sh`** - Custom readline with inline completion
- **`cc`** - Main REPL (integrates completion)
- **`test_slash_complete.sh`** - Unit tests for matching logic
- **`test_cc_readline.sh`** - Interactive test for readline

## Testing

Run unit tests:
```bash
~/.claude/bin/test_slash_complete.sh
```

Interactive test (try typing `/` and commands):
```bash
~/.claude/bin/test_cc_readline.sh
```

## Implementation Notes

### Terminal Control

The custom readline function uses raw terminal mode (`stty -icanon -echo`) to capture individual keystrokes. It handles:

- Regular characters
- Backspace (`\x7f`)
- Enter (`\n`)
- Tab (`\t`)
- Escape sequences (arrow keys: `\x1b[C`, `\x1b[D`)
- Control characters (Ctrl+C, Ctrl+D)

### ANSI Escape Codes

- `\033[90m` - Gray text (for suggestions)
- `\033[0m` - Reset color
- `\033[K` - Clear to end of line
- `\033[ND` - Move cursor left N positions
- `\r` - Carriage return (move to start of line)

### Fallback

If the custom readline module fails to load, `cc` falls back to standard `read -e` (readline with history but no inline completion).

## Future Enhancements

Possible improvements:

- Multi-word completion (complete after spaces too)
- Show multiple suggestions (not just inline)
- Completion scoring based on usage frequency
- Support for command arguments/parameters
- Syntax highlighting for slash commands

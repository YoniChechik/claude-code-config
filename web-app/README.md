# ccweb - Claude Code Web UI

Multi-session Claude Code interface with split-pane layout and Tailwind v4 styling.

## Features

- **Split-pane layout** with two independent Claude sessions
- **Slash command autosuggest** (ported from autosuggest.sh)
- **Session headers** showing cwd, model, and timing
- **Directory navigation** sidebar
- **CD tracking** from structured output
- **Streaming responses** with real-time updates
- **Tailwind CSS v4** for styling

## Architecture

```
web-app/
├── app/
│   ├── api/              # Next.js API routes
│   │   ├── commands/     # POST - Send command to Claude
│   │   ├── models/       # GET - List available models
│   │   └── sessions/     # CRUD - Session management
│   ├── layout.tsx        # Root layout
│   └── page.tsx          # Main page
├── components/           # React components
│   ├── AutosuggestInput.tsx   # Slash command autosuggest
│   ├── ChatInput.tsx          # Chat input with submit
│   ├── ChatMessages.tsx       # Message display
│   ├── ChatPane.tsx           # Individual session pane
│   ├── DirectoryNav.tsx       # File browser
│   ├── SessionHeader.tsx      # Session info header
│   └── SplitLayout.tsx        # Split-pane container
├── lib/                  # Utility libraries
│   ├── autosuggest.ts         # Command matching logic
│   ├── cd-tracker.ts          # Directory change tracking
│   ├── claude-client.ts       # Claude SDK wrapper
│   ├── session-manager.ts     # Session state management
│   ├── types.ts               # TypeScript types
│   └── utils.ts               # Utility functions
├── styles/
│   └── globals.css       # Tailwind imports and base styles
└── public/               # Static assets
```

## Prerequisites

- Node.js 18+ (for npm)
- Claude API key

## Setup

1. Install dependencies:
```bash
npm install
```

2. Create `.env.local` file:
```bash
CLAUDE_API_KEY=your_api_key_here
NEXT_PUBLIC_DEFAULT_CWD=/home/ubuntu
# Optional: Custom appended system prompt file path
# CCWEB_APPENDED_SYSTEM_PROMPT_FILE=/path/to/custom/system-prompt.md
```

3. Run development server:
```bash
npm run dev
```

4. Open [http://localhost:3000](http://localhost:3000)

5. Install git hooks (recommended):
```bash
npm run setup-hooks
```

## Pre-Push Hook

A git hook automatically prevents pushing to `main` if tests or build fail for changes in the `web-app` directory. This ensures production quality.

**Runs only on:** `main` branch with web-app changes
**Expected runtime:** ~2 minutes (runs tests and build)
**Skip if needed:** `git push --no-verify`
**To disable:** `rm ../.git/hooks/pre-push`

The hook will:
- Exit early if not pushing to `main` branch
- Exit early if no changes in web-app directory
- Run `npm test` and block push if tests fail
- Run `npm run build` and block push if build fails
- Allow push only if both tests and build succeed

## Custom System Prompt

You can specify a custom appended system prompt file using the `CCWEB_APPENDED_SYSTEM_PROMPT_FILE` environment variable.

**Priority order:**
1. Custom path from request parameter (advanced use case)
2. `CCWEB_APPENDED_SYSTEM_PROMPT_FILE` environment variable
3. Default: `../main_appended_system_prompt.md` (relative to web-app directory)

**Example:**
```bash
export CCWEB_APPENDED_SYSTEM_PROMPT_FILE=/home/user/my-custom-prompt.md
npm run dev
```

The system gracefully handles missing files by returning undefined if the file cannot be read.

## Tailwind CSS v4

This project uses Tailwind CSS v4 (alpha) with the new unified CLI approach:

- **PostCSS plugin**: `@tailwindcss/postcss`
- **Import syntax**: `@import "tailwindcss";` in CSS
- **No config file needed**: Uses defaults with inline customization

## Key Implementation Details

### Structured Output Schema

Both ccui.sh and ccweb use the same schema for structured output:

```typescript
{
  type: "object",
  properties: {
    cwd: { type: "string", description: "Current working directory path" },
    response: { type: "string", description: "Response to user" }
  },
  required: ["cwd", "response"]
}
```

### CD Tracking

The `cd-tracker.ts` module extracts the `cwd` field from Claude's structured output and updates the session's working directory. This mirrors the bash implementation in ccui.sh lines 52 and 102-104.

### Autosuggest

The `AutosuggestInput` component ports the fuzzy matching and suggestion UI from `autosuggest.sh`:

- Activates on `/` character
- Fuzzy matches against slash commands
- Tab to accept, arrows to cycle
- Shows source (builtin, user, project)

### Session Management

Each session maintains:
- Unique ID
- Current working directory
- Message history
- Model name
- Last request duration

Sessions persist in memory during the app lifecycle.

## API Endpoints

### Sessions

- `POST /api/sessions` - Create new session
- `GET /api/sessions` - List all sessions
- `GET /api/sessions/[id]` - Get session by ID
- `DELETE /api/sessions/[id]` - Delete session

### Commands

- `POST /api/commands` - Send command (returns SSE stream)

### Models

- `GET /api/models` - Get available models

## Building for Production

```bash
npm run build
npm start
```

## Known Limitations

- Directory navigation is placeholder (needs API endpoint)
- No session persistence across server restarts
- No authentication/authorization
- Limited error handling for network issues

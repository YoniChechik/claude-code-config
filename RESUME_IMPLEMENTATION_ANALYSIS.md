# /resume Command Implementation Analysis

## Research Findings

### Claude Code's Native Implementation
- **Commands**: `claude --continue` (most recent), `claude --resume` (interactive menu)
- **Storage**: `~/.claude/sessions/` as plain text JSON
- **Features**: Auto-save after each message, `/checkpoint` for mid-session saves, `/rewind` to roll back
- **Problem**: --resume flag currently BROKEN (creates new sessions instead of resuming - see BUG_REPORT_SESSION_RESUME.md)

### Gemini CLI Best Practices
- `/resume` launches interactive browser (not just dropdown)
- Chronologically sorted with preview (message counts, summaries)
- Searchable by ID or content using `/`
- Multiple access methods: interactive + direct ID
- Automatic cleanup policies in settings.json

### Current ccweb Implementation
- **SessionManager**: In-memory only (Map<string, Session>)
- No persistence across server restarts
- Has claudeSessionId field for CLI --resume integration
- **Slash commands from**: user commands, user skills, project commands, project skills, builtins
- **AutosuggestInput**: Fuzzy matching with dropdown suggestions

## Key Design Decisions

### 1. Leverage Existing CLI Session Persistence
**Decision**: DON'T create new persistence layer - USE existing `~/.claude/session-env/<session-id>/` directories

**Rationale**:
- CLI already persists sessions (when --resume works)
- Avoid duplicate session storage
- Enable cross-tool compatibility (CLI ↔ Web)
- Users can resume CLI sessions in web and vice versa

**Implementation**:
- Read session metadata from `~/.claude/session-env/*/` directories
- Parse existing session files to extract: createdAt, lastActivityAt, cwd, message count
- SessionManager.loadPersistedSessions() on startup
- No new persistence code needed - piggyback on CLI

### 2. /resume as Special Command (Not Regular Slash Command)
**Match Gemini/Claude UX**: `/resume` triggers modal picker, not autocomplete dropdown

**Reasoning**:
- Session selection needs richer UI than single-line dropdown
- Need to show: timestamp, cwd, message preview, message count
- Keyboard navigation for 20+ items needs different UX
- Consistent with both Claude Code and Gemini CLI patterns

**Implementation**:
- Add "resume" to BUILTIN_COMMANDS in autosuggest.ts (for discoverability)
- Special-case detection in AutosuggestInput when user types `/resume`
- Show SessionPicker modal instead of normal dropdown
- On selection: load session messages, switch active session

### 3. Session Picker UI Pattern
**Design**: Modal overlay with scrollable list (inspired by tmux/Gemini)

**Features**:
- Chronological sorting (most recent first)
- Each item shows: cwd, relative time, message count, last message preview (50 chars)
- Keyboard nav: arrows, Enter, Esc
- Optional: Search/filter (future enhancement)
- Loading state while reading sessions
- Empty state: "No previous sessions"

**Styling**: Match existing dark theme, similar to command dropdown

### 4. Cross-Tool Session Compatibility
**Goal**: Resume CLI sessions in web, web sessions in CLI

**Technical Approach**:
- Both tools use same `~/.claude/session-env/<id>/` structure
- Web sessions must write compatible format
- CLI --resume should work with web-created sessions
- Session ID format: same generateSessionId() function

## Revised Implementation Plan

### PR1: Session Discovery & Loading (~200 LOC)
**Goal**: Load existing CLI sessions into web SessionManager

**Files**:
- `lib/session-storage.ts` - NEW
  - `discoverPersistedSessions()` - scan `~/.claude/session-env/`
  - `loadSessionMetadata(sessionId)` - parse session directory
  - `loadSessionMessages(sessionId)` - load full conversation
- `lib/session-manager.ts` - UPDATE
  - `loadPersistedSessions()` - call on startup
  - `resumeSession(sessionId)` - load existing vs create new

**No new persistence**: Read-only for MVP. Future PR adds write.

### PR2: /resume Command & API (~150 LOC)
**Goal**: Add /resume to commands, create session list API

**Files**:
- `lib/autosuggest.ts` - UPDATE
  - Add "resume" to BUILTIN_COMMANDS
- `app/api/sessions/recent/route.ts` - NEW
  - GET endpoint returns last 20 sessions
  - Sorted by lastActivityAt descending
  - Returns: id, cwd, createdAt, lastActivityAt, messageCount, lastMessagePreview

### PR3: SessionPicker Component (~300 LOC)
**Goal**: Interactive modal for session selection

**Files**:
- `components/SessionPicker.tsx` - NEW
  - Modal overlay with session list
  - Keyboard navigation (arrows, Enter, Esc)
  - Relative time formatting (2h ago, 1d ago)
  - Loading/empty states
  - onSelect callback with sessionId

**Styling**: Dark theme matching AutosuggestInput dropdown

### PR4: Integration (~150 LOC)
**Goal**: Wire SessionPicker into AutosuggestInput and ChatPane

**Files**:
- `components/AutosuggestInput.tsx` - UPDATE
  - Detect `/resume` specially (not normal fuzzy match)
  - Show SessionPicker instead of dropdown
  - onSelect → emit resume event
- `components/ChatPane.tsx` - UPDATE
  - Handle resume event → load session → switch messages
  - Clear current temp session
  - Auto-focus input after load

## Success Criteria

### Functional
- [ ] Type `/resume` → picker appears (not dropdown)
- [ ] Picker shows last 20 sessions chronologically
- [ ] Click session → restores conversation in current pane
- [ ] Keyboard navigation works (arrows, Enter, Esc)
- [ ] Can resume CLI-created sessions in web
- [ ] Empty state shows helpful message

### Technical
- [ ] No new persistence layer (reuses CLI storage)
- [ ] Session load <500ms
- [ ] Works in multi-pane layout (resume in one pane only)
- [ ] No breaking changes to Session interface

### UX
- [ ] `/resume` discoverable in slash command list
- [ ] Session picker matches existing dark theme
- [ ] Loading states visible during fetch
- [ ] Clear visual feedback on selection

## Risks & Mitigations

### High Risk: CLI --resume Currently Broken
**Issue**: Bug report shows --resume creates new sessions instead of resuming
**Mitigation**: Web implementation is independent - can work even if CLI broken
**Future**: When CLI fixed, both tools benefit from shared storage

### Medium Risk: Session Format Changes
**Issue**: CLI session format might change (currently undocumented)
**Mitigation**: Write defensive parsing with fallbacks
**Testing**: Test with both CLI and web-created sessions

### Low Risk: Large Session Counts
**Issue**: Thousands of sessions could slow picker
**Mitigation**: Limit to 20 most recent (matches Gemini CLI)
**Future**: Add pagination or search if needed

## Estimated Scope
- **Total LOC**: ~800 (reduced from 1050 - no new persistence)
- **PRs**: 4 (focused, incremental)
- **Risk**: Medium (depends on CLI session format stability)
- **Value**: High (cross-tool compatibility + UX parity with Claude Code/Gemini)

## Next Steps
1. Investigate CLI session directory structure (`~/.claude/session-env/`)
2. Parse sample session to understand format
3. Implement session discovery (PR1)
4. Build picker UI (PR3 can be parallel to PR2)
5. Integrate and test cross-tool compatibility

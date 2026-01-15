# Session Preview Improvements - Analysis & Recommendations

## Current Implementation

### What's Shown Now
The session picker modal (`SessionPicker.tsx`) currently displays:
- **Working directory** (cwd)
- **Message count** (e.g., "192 messages")
- **Last message preview** (truncated to 50 chars)
- **Time ago** (e.g., "2h ago")
- **Symlink indicator** (if session was created in another directory)

### The Problem
Users report that it's hard to understand what each session was about. With only:
- "192 messages"
- Last message preview: "< system-reminder > The TodoWrite tool hasn'..."

It's nearly impossible to distinguish between sessions or remember which one you need to resume.

## Available Data (from Analysis)

After analyzing the session JSONL files, here's what we have access to:

### Currently Used
- ✅ Session ID
- ✅ CWD (working directory)
- ✅ Message count
- ✅ Last user message preview
- ✅ Created at timestamp
- ✅ Last activity timestamp
- ✅ Symlink status

### Available But NOT Used
- ❌ **First user message** - Often contains the task/goal description
- ❌ **Tool usage patterns** - Shows what was done (Read: 44, Write: 3, Bash: 185, etc.)
- ❌ **Session duration** - Time between first and last activity
- ❌ **User/assistant message ratio** - Indicates interactivity
- ❌ **Multiple CWDs** - Shows if directory changed during session
- ❌ **Assistant text length** - Rough indicator of how much explanation/output
- ❌ **Version info** - Which Claude Code version created the session
- ❌ **Git branch** - What branch was active during session

## Recommended Approaches (Ranked)

### 🥇 Approach 1: Show First User Message (Simplest & Most Effective)

**Why**: The first user message almost always describes what the session is about.

**Changes**:
```typescript
// In session-storage.ts, _loadSessionMetadata()
// Instead of only finding last message preview:

let firstUserMessage = "";
let lastUserMessage = "";

for (let i = 0; i < lines.length; i++) {
  const line: SessionLine = JSON.parse(lines[i]);
  if (line.type === "user" && line.message) {
    if (!firstUserMessage) {
      firstUserMessage = extractTextFromMessage(line.message);
    }
    lastUserMessage = extractTextFromMessage(line.message);
  }
}

// Return both in metadata
return {
  // ... existing fields
  firstUserMessage: firstUserMessage.substring(0, 80) + "...",
  lastUserMessage: lastUserMessage.substring(0, 50) + "...",
};
```

**UI Changes**:
```tsx
// In SessionPicker.tsx
<div className="text-sm font-semibold text-gray-200 mb-1">
  {session.firstUserMessage}
</div>
<div className="text-xs text-gray-400 italic">
  Last: "{session.lastUserMessage}"
</div>
```

**Pros**:
- Simple to implement
- Most effective for understanding session purpose
- No complex calculations
- Minimal performance impact

**Cons**:
- First message might be a skill command like `/new-feature-short`
- May need filtering for command messages

**Example Display**:
```
📁 /home/ubuntu/.claude/_clones/fix-auth-bug
   "Fix authentication bug where JWT tokens expire too soon"
   85 messages • 2h ago
   Last: "The issue is in src/auth/tokens.ts:42..."
```

---

### 🥈 Approach 2: Add Tool Usage Summary (Most Informative)

**Why**: Tool usage tells you WHAT was done in the session.

**Changes**:
```typescript
// In session-storage.ts
interface SessionMetadata {
  // ... existing
  toolSummary: string; // "Read: 44, Write: 3, Bash: 185"
  primaryActivity: "coding" | "research" | "discussion" | "mixed";
}

// Calculate during metadata loading
const toolUses = {};
// ... count tools from assistant messages

// Generate summary
const topTools = Object.entries(toolUses)
  .sort((a, b) => b[1] - a[1])
  .slice(0, 3)
  .map(([tool, count]) => `${tool}: ${count}`)
  .join(", ");

// Determine primary activity
let primaryActivity = "discussion";
if (toolUses.Edit > 5 || toolUses.Write > 2) {
  primaryActivity = "coding";
} else if (toolUses.Read > 10 || toolUses.Grep > 5) {
  primaryActivity = "research";
}
```

**UI Changes**:
```tsx
<div className="flex items-center gap-2 text-xs text-gray-400">
  <span className="px-2 py-0.5 bg-blue-900 text-blue-200 rounded">
    {session.primaryActivity}
  </span>
  <span className="font-mono">{session.toolSummary}</span>
</div>
```

**Pros**:
- Shows concrete actions taken
- Helps identify coding vs research sessions
- Useful for understanding session complexity

**Cons**:
- More complex to compute
- Requires parsing all assistant messages
- Performance impact on large sessions

**Example Display**:
```
📁 /home/ubuntu/.claude/_clones/add-dark-mode
   "Add dark mode toggle to the application"
   [coding] Edit: 12, Write: 3, Bash: 8
   156 messages • 4h ago
```

---

### 🥉 Approach 3: Smart Preview with Context (Best UX)

**Why**: Combines multiple signals to give the most useful preview.

**Changes**:
```typescript
interface SessionMetadata {
  title: string; // Smart-generated title
  subtitle: string; // Context line
  tags: string[]; // ["feature", "typescript", "testing"]
}

function generateSmartPreview(lines: SessionLine[]): {
  title: string;
  subtitle: string;
  tags: string[];
} {
  // Get first user message
  const firstUser = findFirstUserMessage(lines);

  // Remove command prefixes
  let title = firstUser.replace(/<command-.*?>/g, '').trim();

  // If starts with skill name, clean it
  if (title.startsWith('/')) {
    title = title.split('\n')[1] || title;
  }

  // Limit to one line
  title = title.split('\n')[0].substring(0, 80);

  // Generate subtitle from activity
  const messageCount = lines.filter(l => l.message).length;
  const duration = calculateDuration(lines);
  subtitle = `${messageCount} messages over ${duration}`;

  // Auto-generate tags
  const tags = [];
  const toolUses = countTools(lines);
  if (toolUses.Edit > 5 || toolUses.Write > 2) tags.push('coding');
  if (toolUses.Task > 0) tags.push('agents');
  if (duration < '1h') tags.push('quick');

  return { title, subtitle, tags };
}
```

**UI Changes**:
```tsx
<div>
  <div className="text-sm font-semibold text-gray-200 mb-1">
    {session.title}
  </div>
  <div className="flex items-center gap-2 text-xs text-gray-400 mb-1">
    <span>{session.subtitle}</span>
    {session.tags.map(tag => (
      <span key={tag} className="px-2 py-0.5 bg-gray-700 text-gray-300 rounded">
        {tag}
      </span>
    ))}
  </div>
  <div className="text-xs text-gray-500 italic truncate">
    "{session.lastUserMessage}"
  </div>
</div>
```

**Pros**:
- Best user experience
- Most context at a glance
- Professional appearance
- Helps with quick scanning

**Cons**:
- Most complex to implement
- Requires careful title generation
- May need iteration to get right
- Highest performance cost

**Example Display**:
```
📁 /home/ubuntu/.claude/_clones/fix-auth-bug
   Fix authentication bug where JWT tokens expire too soon
   85 messages over 3h • [coding] [typescript]
   "The issue is in src/auth/tokens.ts:42..."
```

---

## Additional Enhancement Ideas

### 1. Session Thumbnails
Show mini-preview of code changes or key files touched:
```
📄 Files: src/auth/tokens.ts (+45, -12), src/utils/jwt.ts (+8, -3)
```

### 2. Outcome Indicator
Show if session ended with success/error/incomplete:
```
✅ Completed | ⚠️ Has errors | 🔄 In progress
```

### 3. Search/Filter
Add search box to filter sessions by:
- Content
- Directory
- Date range
- Activity type

### 4. Session Categories
Auto-categorize:
- 🐛 Bug fixes (mentions "bug", "fix", "error")
- ✨ Features (mentions "add", "new", "feature")
- 📚 Research (heavy Read/Grep usage)
- 🧪 Testing (mentions "test", uses pytest/jest)

### 5. Preview on Hover
Show expanded preview in tooltip:
```
On hover:
┌─────────────────────────────────────────┐
│ Session: Fix auth bug                    │
│ Started: Jan 15, 2:30 PM                 │
│ Duration: 3h 15m                         │
│ Messages: 85 (45 user, 40 assistant)    │
│                                          │
│ First: "Fix authentication bug where    │
│        JWT tokens expire too soon..."   │
│                                          │
│ Tools: Edit: 12, Read: 8, Bash: 15      │
│ Files: 5 modified                        │
└─────────────────────────────────────────┘
```

## Performance Considerations

### Current Implementation
- Reads entire file for each session
- Parses all lines
- Already has performance cost

### Optimization Strategies

1. **Lazy Loading**
   - Only load basic metadata initially
   - Load rich metadata on scroll/demand

2. **Caching**
   - Cache computed metadata in `.meta.json` files
   - Invalidate cache on file mtime change

3. **Indexing**
   - Pre-compute metadata on session close
   - Store in separate index file

4. **Partial Reads**
   - Only read first N and last N lines
   - Use file streaming for large sessions

## Recommended Implementation Plan

### Phase 1: Quick Win ⚡ (1-2 hours)
- Implement Approach 1: Show first user message
- Add first message to `SessionMetadata` interface
- Update UI to display prominently
- Filter out command wrapper text

### Phase 2: Enhanced Context 📊 (2-4 hours)
- Add session duration display
- Show activity indicator (coding/research/discussion)
- Add basic tool usage summary (top 2-3 tools)

### Phase 3: Polish & Performance 🎨 (4-8 hours)
- Implement smart title generation
- Add tags/categories
- Add caching layer
- Performance optimization for large session lists

### Phase 4: Advanced Features 🚀 (Optional)
- Search/filter functionality
- Hover previews
- Session thumbnails
- Outcome indicators

## Testing Approach

1. **Create test script** that generates mock sessions with various patterns
2. **Manual testing** with actual sessions from analysis
3. **Performance testing** with 100+ sessions
4. **User testing** to validate improvements

## Conclusion

**Recommended starting point**: Implement Approach 1 (First User Message) as it provides the biggest improvement with minimal effort.

The current "192 messages" display is inadequate. By showing the first user message (which typically describes the goal), users can immediately identify their sessions.

After validating that improvement, layer on tool usage summaries and smart categorization for an even better experience.

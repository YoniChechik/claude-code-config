# Multi-Pane Session Decoupling Analysis

## Executive Summary

**Status: ✓ FULLY DECOUPLED**

All cross-session pane interactions have been analyzed and fixed. Panes from different sessions are now completely isolated.

---

## Issues Found & Fixed

### 1. Notification System Coupling ❌ → ✓ FIXED

**Problem:**
- Global `originalTitle` variable shared across all panes
- Race condition when multiple panes complete tasks simultaneously
- Each pane had redundant `visibilitychange` listeners

**Race Condition Example:**
```
1. Pane A (session-123) completes → saves originalTitle → sets title "Done"
2. Pane B (session-456) completes → OVERWRITES originalTitle → sets title "Done"
3. User focuses tab → Pane B clears notification → Pane A's notification LOST
```

**Solution Implemented:**
- Created `NotificationManager` class with per-session tracking
- Lifted visibility state from ChatPane to SplitLayout (single source of truth)
- Eliminated N redundant event listeners → 1 listener for entire app
- Aggregate notifications: "N tasks done" instead of "Done"

**Files Changed:**
- `web-app/lib/notification-manager.ts` (new)
- `web-app/lib/notifications.ts` (deleted)
- `web-app/components/ChatPane.tsx`
- `web-app/components/SplitLayout.tsx`

**Commit:** `86a80a5` - "refactor: decouple pane notifications with session-aware manager"

---

### 2. Working Directory (CWD) Isolation ✓ VERIFIED

**Status: Already Decoupled**

**Architecture:**
- Each session has dedicated `Session` object with unique `cwd` field
- Each session has dedicated `CDTracker` instance
- No shared state between sessions

**Flow:**
```
Pane A: cd /home/foo
  ↓
CDTracker A tracks wanted_cwd = /home/foo
  ↓
SessionManager updates Session A.cwd ONLY
  ↓
cwd_changed event sent ONLY to Pane A's SSE stream
  ↓
Pane A updates local session state
```

**Isolation Guarantees:**
- `CDTracker` is per-session instance (session-manager.ts:8)
- `cwd_changed` events are stream-specific (SSE isolated by HTTP request)
- Each ChatPane has local `session` state with its own `cwd`
- No global cwd variable exists

**Verification:**
```typescript
// session-manager.ts:7-8
private sessions = new Map<string, Session>();
private cdTrackers = new Map<string, CDTracker>();
```

When Pane A does `cd /foo` and Pane B does `cd /bar`:
- Session A.cwd = "/foo"
- Session B.cwd = "/bar"
- No interference possible

---

## Architecture Overview

### Session Isolation Model

```
┌─────────────────────────────────────────────────────────┐
│                     SplitLayout                         │
│  - Single visibilitychange listener                    │
│  - Passes isWindowFocused prop to all panes            │
│  - NotificationManager.clearAll() on focus             │
└─────────────────────────────────────────────────────────┘
                          │
        ┌─────────────────┼─────────────────┐
        ▼                 ▼                 ▼
   ┌─────────┐       ┌─────────┐       ┌─────────┐
   │ Pane A  │       │ Pane B  │       │ Pane C  │
   │ sess-1  │       │ sess-2  │       │ sess-3  │
   └─────────┘       └─────────┘       └─────────┘
        │                 │                 │
        ▼                 ▼                 ▼
   ┌─────────┐       ┌─────────┐       ┌─────────┐
   │Session 1│       │Session 2│       │Session 3│
   │cwd: /foo│       │cwd: /bar│       │cwd: /baz│
   │tracker 1│       │tracker 2│       │tracker 3│
   └─────────┘       └─────────┘       └─────────┘
```

### Notification Flow

```
Pane A completes task
  ↓
notificationManager.notifyComplete("session-1")
  ↓
NotificationManager.pendingNotifications.add("session-1")
  ↓
Document title updated: "1 task done - Original Title"

Pane B completes task
  ↓
notificationManager.notifyComplete("session-2")
  ↓
NotificationManager.pendingNotifications.add("session-2")
  ↓
Document title updated: "2 tasks done - Original Title"

User focuses tab
  ↓
SplitLayout's visibilitychange handler
  ↓
notificationManager.clearAll()
  ↓
Document title restored: "Original Title"
```

---

## No Shared Mutable State

### Before (Coupled)
```typescript
// notifications.ts
let originalTitle: string | null = null;  // ← GLOBAL STATE

// ChatPane.tsx (N instances)
useEffect(() => {
  const handleVisibilityChange = () => {
    if (!document.hidden) {
      clearTabNotification();  // ← N listeners calling same function
    }
  };
  document.addEventListener("visibilitychange", handleVisibilityChange);
}, []);
```

### After (Decoupled)
```typescript
// notification-manager.ts
class NotificationManager {
  private pendingNotifications = new Set<string>();  // ← Per-session tracking
  private originalTitle: string | null = null;       // ← Encapsulated
}

// SplitLayout.tsx (1 instance)
useEffect(() => {
  const handleVisibilityChange = () => {
    if (!document.hidden) {
      notificationManager.clearAll();  // ← 1 listener
    }
  };
  document.addEventListener("visibilitychange", handleVisibilityChange);
}, []);

// ChatPane.tsx
notificationManager.notifyComplete(sessionId);  // ← Session-aware
```

---

## Testing Scenarios

### Scenario 1: Concurrent Task Completion
```
✓ Pane A completes → title: "1 task done"
✓ Pane B completes → title: "2 tasks done"
✓ Pane C completes → title: "3 tasks done"
✓ User focuses tab → title restored correctly
```

### Scenario 2: Directory Changes
```
✓ Pane A: cd /home/alice → Pane A shows /home/alice
✓ Pane B: cd /tmp → Pane B shows /tmp
✓ Pane A still shows /home/alice (no interference)
```

### Scenario 3: Notification Acknowledgment
```
✓ Pane A, B, C complete tasks
✓ User focuses tab → all notifications cleared
✓ No "ghost" notifications remain
```

---

## Verification Checklist

- [x] No global state shared between panes
- [x] Each session has isolated cwd tracking
- [x] Each session has isolated CDTracker instance
- [x] Notifications are per-session
- [x] Single visibility event listener
- [x] No race conditions in notification system
- [x] Build passes successfully
- [x] Linter improvements applied (fail-fast in session-manager.ts)

---

## Future Considerations

### Potential Areas to Monitor

1. **Audio Notifications**
   - Currently: Per-pane setting (session.audioNotificationsEnabled)
   - If multiple panes complete, multiple beeps may play
   - Consider: Debouncing or single beep for aggregate notifications

2. **Token Usage Display**
   - Currently: Per-pane display
   - Consider: Optional aggregate view across all sessions

3. **Session Recovery**
   - Currently: Per-session ownership validation
   - Already properly isolated via windowId checks

### Non-Issues (Already Decoupled)

- ✓ Message history (per-session)
- ✓ Streaming state (per-pane)
- ✓ Model selection (per-session)
- ✓ Session metadata (per-session)
- ✓ Keyboard shortcuts (global, but non-interfering)

---

## Conclusion

All cross-session pane coupling has been eliminated. The architecture now follows proper isolation principles:

1. **State Isolation**: Each session maintains its own state
2. **Event Isolation**: Single source of truth for shared events
3. **No Race Conditions**: Per-session tracking prevents interference
4. **Fail-Fast**: Linter improvements ensure errors are caught early

The multi-pane system is now production-ready for concurrent sessions.

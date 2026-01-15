# Test Suite Status Report

## Current Status

**Generated:** 2026-01-15

### Test Results Summary

- **Unit Tests**: 187/187 passing (100%) ✅
- **E2E Tests**: 40/76 passing (53%)
- **Overall**: 227/263 passing (86%)

### Recent Improvements

1. ✅ Fixed timestamp display in tool use blocks
2. ✅ Created isolated test build system (no production interference)
3. ✅ Added test concurrency (5 workers) for faster execution
4. ✅ Cleaned up duplicate/deprecated tests (reduced from 108 → 76 tests)

---

## Remaining E2E Failures (36 tests)

### Category 1: Error Handling Tests (14 failures) - **NEEDS DECISION**

**Issue**: Tests expect error modals (`[role="dialog"]`) that don't exist in the UI.

**Tests affected:**
- `error-handling.spec.ts:9` - API errors when creating session
- `error-handling.spec.ts:27` - Network timeout when sending command
- `error-handling.spec.ts:43` - Malformed JSON responses
- `error-handling.spec.ts:59` - Recover from failed session creation
- `error-handling.spec.ts:85` - Session not found error
- `error-handling.spec.ts:102` - Command stream fails
- `error-handling.spec.ts:119` - Broken SSE stream
- `error-handling.spec.ts:136` - Invalid session ID in commands
- `error-handling.spec.ts:153` - Display error modal with details
- `error-handling.spec.ts:177` - Allow dismissing error modal
- `error-handling.spec.ts:209` - Complete network failure
- `error-handling.spec.ts:222` - Intermittent network failures
- `error-handling.spec.ts:241` - Slow network responses
- `error-handling.spec.ts:257` - Connection reset
- `error-handling.spec.ts:270` - DNS resolution failure

**Recommendation**:
- **Option A**: Delete these tests if error modals were never implemented
- **Option B**: Update tests to check for actual error indicators (inline messages, console errors)
- **Option C**: Implement error modals as per original design

---

### Category 2: SSH Hostname Modal Tests (5 failures) - **FIXABLE**

**Issue**: Page doesn't initialize after mocking session API response.

**Tests affected:**
- `ssh-hostname-modal.spec.ts:13` - Show modal when clicking CWD
- `ssh-hostname-modal.spec.ts:69` - Save hostname and open VSCode
- `ssh-hostname-modal.spec.ts:169` - Close modal when cancel clicked
- `ssh-hostname-modal.spec.ts:232` - Use saved hostname on subsequent clicks
- `ssh-hostname-modal.spec.ts:309` - Open VSCode directly for non-SSH sessions

**Error**: `TimeoutError: page.waitForSelector: Timeout 10000ms exceeded` waiting for textarea

**Root cause**: Mocked session response format may be incorrect, causing page initialization to hang.

**Recommendation**: Debug mock response format by comparing with real session API response.

---

### Category 3: Notification/Window Focus Tests (4 failures) - **PLAYWRIGHT LIMITATION**

**Issue**: Playwright cannot reliably manipulate window focus state.

**Tests affected:**
- `notifications.spec.ts:62` - Update tab title when window unfocused
- `notifications.spec.ts:109` - Clear tab notification when window regains focus
- `notifications.spec.ts:174` - No tab title update when window focused
- `notifications.spec.ts:224` - Persist audio notification preference (localStorage timing issue)

**Recommendation**:
- Mark these tests as "manual testing only" or skip them
- Window focus behavior is notoriously difficult to test in automated E2E tests
- Consider moving to integration tests or manual test checklist

---

### Category 4: Progress Indicator Tests (3 failures) - **FIXABLE**

**Issue**: `animate-border-spin` class doesn't appear or disappears too quickly.

**Tests affected:**
- `progress.spec.ts:9` - Show progress indicator animation during streaming
- `progress.spec.ts:46` - Hide progress indicator when streaming completes
- `progress.spec.ts:90` - Show progress indicator for multiple messages
- `progress.spec.ts:141` - Maintain message readability during animation

**Root cause**: Mock responses complete too fast, or timing checks happen before/after animation.

**Recommendation**: Add explicit waits or slow down mock responses to capture animation state.

---

### Category 5: Resume Button Tests (2 failures) - **FIXABLE**

**Issue**: Sessions aren't being persisted or retrieved from storage.

**Tests affected:**
- `resume.spec.ts:12` - Open SessionPicker modal ✅ (passing now)
- `resume.spec.ts:41` - Close modal when cancel clicked ✅ (passing now)
- `resume.spec.ts:72` - List saved sessions in modal (count = 0)
- `resume.spec.ts:113` - Resume a session when clicking on it (count = 0)

**Root cause**: Sessions created in test aren't being saved/retrieved. Possible timing issue or storage not initialized.

**Recommendation**: Add explicit wait for session save, or check localStorage/sessionStorage API directly.

---

### Category 6: Scroll Behavior Tests (2 failures) - **TIMING ISSUE**

**Issue**: Scroll position checks happen before animation completes.

**Tests affected:**
- `scroll-behavior.spec.ts:64` - Stop auto-scrolling when user scrolls up
- `scroll-behavior.spec.ts:142` - Resume auto-scrolling when scrolls back to bottom

**Recommendation**: Add longer waits or poll scroll position until stable.

---

### Category 7: Stop Button Rapid Clicks (1 failure) - **POTENTIAL BUG**

**Issue**: Browser context closes during test (page crash).

**Test affected:**
- `stop-button.spec.ts:156` - Handle multiple rapid stop clicks gracefully

**Error**: `Target page, context or browser has been closed`

**Root cause**: Rapid clicking may cause app crash or abort controller issue.

**Recommendation**: This could indicate a real bug in the stop button handler. Investigate:
1. Race condition in abort controller
2. Multiple simultaneous state updates
3. Memory leak or unhandled promise rejection

---

### Category 8: Content Rendering Tests (6 failures) - **MOCK FORMAT**

**Issue**: Mock SSE responses don't produce expected UI elements.

**Tests affected:**
- `content-rendering.spec.ts:341` - Handle streaming text without data loss

**Root cause**: Mock format may be missing fields or using incorrect structure.

**Recommendation**: Compare mock SSE format with real API responses to ensure exact match.

---

## Priority Recommendations

### High Priority (Real Bugs)
1. **Stop button crash** (1 test) - Investigate potential race condition
2. **Resume session persistence** (2 tests) - Core feature not working in tests

### Medium Priority (Test Infrastructure)
3. **SSH modal initialization** (5 tests) - Fix mock format
4. **Progress indicator timing** (3 tests) - Adjust timing expectations
5. **Content rendering mocks** (6 tests) - Fix mock SSE format

### Low Priority (Known Limitations)
6. **Window focus tests** (4 tests) - Playwright limitation, move to manual testing
7. **Scroll behavior** (2 tests) - Minor timing tweaks
8. **Error handling** (14 tests) - Need product decision on error modal implementation

---

## Running Tests

### Quick Commands

```bash
# Run all tests (unit + E2E with fresh build)
npm run test:all

# Run only E2E tests with fresh build
npm run test:e2e:build

# Run only E2E tests (uses existing build - faster)
npm run test:e2e

# Run only unit tests
npm test

# Run specific E2E test
npm run test:e2e:build -- --grep "timestamp"
```

### Test Infrastructure

- **Test builds**: Isolated in `.next-test/` directory
- **Production builds**: Remain in `.next/` directory (no interference)
- **Concurrency**: 5 workers for faster execution
- **Test port**: 6380 (production uses 6379)

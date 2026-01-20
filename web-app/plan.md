# Web-App Implementation Plan

## Executive Summary

The project has recently completed:
1. Added a real end-to-end test (`real-response.spec.ts`) that validates complete Claude API integration without mocks
2. Modified `ChatPane.tsx` to include `windowId` in API requests (already uncommitted)

**Current Status:** Changes need to be committed and the e2e test needs to be validated to ensure it passes with real Claude responses.

**Immediate Next Steps:**
- Commit pending changes (.version bump + ChatPane.tsx modifications)
- Run the new e2e test to verify it passes with actual Claude responses
- Identify any test failures and fix them
- Consider integrating the test into CI/CD pipeline

---

## What's Being Done

### Recent Changes (Uncommitted)

1. **ChatPane.tsx modification**
   - Added `windowId` capture via `getOrCreateWindowId()`
   - Updated API request body to include `windowId` alongside `sessionId` and `prompt`
   - Enables window-scoped session tracking for better multi-window support

2. **.version bump**
   - Version file updated (shows `3e20ca5` commit)

3. **New e2e test: real-response.spec.ts**
   - Tests complete end-to-end flow: UI → API → Claude CLI → streaming response → UI rendering
   - Uses **real Claude API calls** (no mocks)
   - Sends simple "hi" prompt and validates actual Claude response appears
   - Includes robust selectors for async response detection with 30-second timeout
   - Validates response persists and UI recovers for next message

---

## Implementation Phases

### Phase 1: Commit Current Changes (Easy)
**Goal:** Save uncommitted work with clear commit messages

**Steps:**
1. Stage modified files (.version, ChatPane.tsx)
2. Create commit message explaining windowId addition
3. Verify commit contains all pending changes

**Difficulty:** Easy

---

### Phase 2: Validate E2E Test (Medium)
**Goal:** Run the new real-response test and ensure it passes consistently

**Steps:**
1. Run `npm run test:e2e` targeting `real-response.spec.ts`
2. If test passes: Verify it's reliable (run multiple times)
3. If test fails: Analyze failure reason
   - Check if Claude API is accessible
   - Verify .env.local has valid CLAUDE_API_KEY
   - Review selector robustness for response detection
   - Check API response streaming works correctly
4. Document any adjustments needed

**Difficulty:** Medium (depends on environmental factors like API availability)

---

### Phase 3: Update Test Suite Configuration (Medium)
**Goal:** Ensure the new test is properly integrated into test pipeline

**Potential tasks:**
- Add skip/focus annotation if test needs special handling
- Consider adding to dedicated e2e suite (separate from unit tests)
- Document test requirements (API key needed, real calls made)
- Add performance baseline if response time matters

**Difficulty:** Medium

---

### Phase 4: Consider API Backend Support (Medium)
**Goal:** Verify backend correctly handles `windowId` in requests

**Check:**
- Review `/api/commands` endpoint to ensure it receives and uses `windowId`
- Verify no breaking changes to existing functionality
- Consider if `windowId` needs to be persisted/logged

**Difficulty:** Medium

---

## Architecture Notes

### Session Management Enhancement
The `windowId` addition enables:
- Per-window session tracking (multiple browser tabs can have independent sessions)
- Better correlation of requests to UI windows
- Improved logging and debugging of multi-window scenarios

### Test Strategy
- **Unit tests**: Test individual components (existing)
- **Integration tests**: Test API + component interaction (existing)
- **E2E tests with mocks**: Test complete flow safely (existing)
- **E2E tests with real API**: Validate actual Claude integration (NEW - real-response.spec.ts)

---

## Success Criteria

- [ ] Uncommitted changes committed successfully
- [ ] real-response.spec.ts passes at least once with actual Claude response
- [ ] ChatPane.tsx correctly sends windowId to API
- [ ] Backend API properly receives windowId parameter
- [ ] No regression in existing tests

---

## Known Risks

1. **API Rate Limiting**: Real e2e test makes actual Claude API calls - could hit rate limits if run too frequently
2. **API Key Dependency**: Test only works if valid CLAUDE_API_KEY in .env.local
3. **Network Issues**: Real API calls can fail due to network problems
4. **Response Variability**: Claude's response length/format varies, test selectors must be robust

---

## Dependencies

- Valid Claude API key (CLAUDE_API_KEY in .env.local)
- Internet connectivity to Claude API
- Playwright test environment configured
- Node.js and npm dependencies installed

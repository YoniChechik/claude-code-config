# Migrate Playwright E2E Tests to Integration Tests

## Executive Summary

**Goal**: Migrate 12 Playwright E2E tests to faster @testing-library/react integration tests where appropriate, while retaining E2E coverage for scenarios requiring full browser automation.

**Scope**: Single PR (~150-200 LOC of new tests, deletion of ~1500 LOC of E2E tests that become redundant)

**Approach**:
- Convert 9 test files fully to integration tests (component + mocked API)
- Keep 2 test files as E2E smoke tests (tab-close-cleanup, scroll-behavior)
- Delete 1 test file (session-init) as it duplicates existing coverage

**Impact**:
- Test execution time: ~3-5 minutes E2E -> ~10-15 seconds integration
- Flakiness reduction: E2E tests have timing issues; integration tests are deterministic
- Developer experience: Faster feedback loop, easier debugging

**Key Decisions**:
1. E2E tests that only verify component rendering/behavior -> Integration tests
2. E2E tests requiring browser APIs (scroll, pagehide) -> Keep as E2E
3. API endpoint tests already exist in `__tests__/*.test.ts` -> Remove from E2E

---

## Current State Analysis

### E2E Test Files (12 total)

| File | Lines | What it Tests | Category |
|------|-------|---------------|----------|
| chat.spec.ts | 164 | Message sending, response display, tool timestamps | CONVERT |
| consecutive-streaming.spec.ts | 179 | Multiple message streaming | CONVERT |
| content-rendering.spec.ts | 551 | Text, thinking blocks, tool use rendering | CONVERT |
| notifications.spec.ts | 61 | Audio toggle button | CONVERT |
| progress.spec.ts | 133 | Streaming animation indicator | CONVERT |
| resume.spec.ts | 266 | Session resume modal | CONVERT |
| scroll-behavior.spec.ts | 124 | Auto-scroll during streaming | KEEP E2E |
| session-init.spec.ts | 87 | App initialization | DELETE |
| ssh-hostname-modal.spec.ts | 355 | SSH hostname configuration modal | CONVERT |
| stop-button.spec.ts | 242 | Stop button show/hide/click | CONVERT |
| tab-close-cleanup.spec.ts | 216 | Cleanup on tab close, heartbeat | KEEP E2E |
| url-detection.spec.ts | 297 | URL rendering as clickable links | CONVERT |

### Existing Integration Tests (relevant patterns)

| File | Pattern Used |
|------|--------------|
| StopButton.test.tsx | Pure component testing with `render()`, `fireEvent` |
| SessionHeader.test.tsx | Component with mocked `fetch`, async state handling |
| ChatMessages.test.tsx | Message rendering with mock data utilities |
| link-detector.test.ts | Pure unit test for URL parsing logic |

---

## Target State

### Integration Tests to Create

1. **`__tests__/components/ChatInput.test.tsx`** (NEW)
   - Message submission
   - Empty message prevention
   - Input clearing after send

2. **`__tests__/components/ContentBlockRenderer.test.tsx`** (NEW)
   - Text block rendering
   - Thinking block rendering with styling
   - Tool use block rendering
   - Tool result block expand/collapse

3. **`__tests__/components/SessionPicker.test.tsx`** (NEW)
   - Modal open/close
   - Session list display
   - Session selection

4. **`__tests__/components/SSHHostPromptModal.test.tsx`** (NEW)
   - Modal display
   - Hostname input and save
   - Cancel behavior

5. **`__tests__/integration/ChatFlow.test.tsx`** (NEW)
   - Full chat flow with mocked streaming
   - Consecutive message handling
   - Stop button integration with ChatMessages

### E2E Tests to Keep (Smoke Tests)

1. **`e2e/scroll-behavior.spec.ts`** - Requires real scroll position tracking
2. **`e2e/tab-close-cleanup.spec.ts`** - Requires pagehide event, real network timing

### E2E Tests to Delete

All others after integration test coverage is complete.

---

## Implementation Phases

### Phase 1: Low-Hanging Fruit (Easy)

**Files**: 4 new test files, ~200 LOC total
**What**: Tests that map 1:1 to existing component tests

| E2E File | Integration Test | Mocks Required |
|----------|------------------|----------------|
| notifications.spec.ts | SessionHeader.test.tsx (extend) | None - already covered |
| stop-button.spec.ts | StopButton.test.tsx (extend) | None - already covered |
| url-detection.spec.ts | link-detector.test.ts (covered) + ContentBlockRenderer.test.tsx | None |
| progress.spec.ts | ChatMessages.test.tsx (covered) | None |

**Tasks**:
1. Verify existing integration tests cover all E2E scenarios
2. Add missing edge cases from E2E to existing integration tests
3. Delete redundant E2E files

### Phase 2: Content Rendering (Medium)

**Files**: 2 new test files, ~150 LOC total
**What**: Component tests for complex rendering

| E2E File | Integration Test | Mocks Required |
|----------|------------------|----------------|
| content-rendering.spec.ts | ContentBlockRenderer.test.tsx (NEW) | Mock message data |
| chat.spec.ts | ChatInput.test.tsx (NEW) + ChatMessages extend | Mock onSend callback |

**Tasks**:
1. Create ContentBlockRenderer.test.tsx
   - Test all content block types (text, thinking, tool_use, tool_result)
   - Test expand/collapse for tool results
   - Test timestamp display
2. Create ChatInput.test.tsx
   - Test message submission via Enter
   - Test empty message prevention
   - Test input clearing

### Phase 3: Modal Interactions (Medium)

**Files**: 2 new test files, ~150 LOC total
**What**: Modal component tests with mocked API

| E2E File | Integration Test | Mocks Required |
|----------|------------------|----------------|
| resume.spec.ts | SessionPicker.test.tsx (NEW) | Mock fetch for sessions |
| ssh-hostname-modal.spec.ts | SSHHostPromptModal.test.tsx (extend SessionHeader) | Mock fetch, window.open |

**Tasks**:
1. Create SessionPicker.test.tsx
   - Test modal open/close
   - Test session list rendering
   - Test session selection callback
2. Extend SessionHeader.test.tsx with remaining SSH modal tests (most already exist)

### Phase 4: Integration Flow Tests (Medium)

**Files**: 1 new test file, ~100 LOC
**What**: Integration tests simulating full user flows

| E2E Files | Integration Test | Mocks Required |
|-----------|------------------|----------------|
| consecutive-streaming.spec.ts | ChatFlow.test.tsx (NEW) | Mock streaming responses |
| chat.spec.ts (remaining) | ChatFlow.test.tsx (NEW) | Mock streaming responses |

**Tasks**:
1. Create ChatFlow.test.tsx
   - Render ChatPane with all child components
   - Mock API responses for streaming
   - Test consecutive message handling
   - Test tool use display in conversation flow

### Phase 5: Cleanup (Easy)

**Tasks**:
1. Delete converted E2E test files
2. Update CI configuration if needed
3. Remove session-init.spec.ts (duplicates app initialization which is implicitly tested)

---

## Testing Strategy

### What to Mock

| Dependency | Mock Strategy |
|------------|---------------|
| API calls (`/api/commands`) | `jest.mock('fetch')` with streaming response simulation |
| API calls (`/api/sessions/*`) | `jest.mock('fetch')` with JSON responses |
| `window.open` | `jest.spyOn(window, 'open')` |
| Timestamps | Fixed Date for consistent snapshots |

### Test Data Utilities

Extend existing `__tests__/utils/mockData.ts`:

```typescript
// Add these helpers
export const createStreamingResponse = (chunks: string[]) => {...}
export const createMockSession = (overrides?: Partial<Session>) => {...}
export const createThinkingBlock = (content: string) => {...}
```

### Coverage Goals

| Category | Target |
|----------|--------|
| Component rendering | 100% of content block types |
| User interactions | Submit, click, toggle, expand/collapse |
| Error states | API failures, validation errors |
| Loading states | Streaming indicators, modal loading |

---

## Dependencies

### Required Packages (Already Installed)
- `@testing-library/react`
- `@testing-library/jest-dom`
- `jest`

### No New Dependencies Required

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Missing coverage after E2E removal | Medium | High | Run both test suites in parallel during migration, compare coverage reports |
| Mocked streaming doesn't match real behavior | Low | Medium | Use recorded API responses from actual Claude interactions |
| Integration tests don't catch CSS/layout issues | Medium | Low | Keep 2 E2E smoke tests for visual sanity |
| Tests become flaky with timing | Low | Medium | Use `waitFor` and `findBy*` instead of fixed timeouts |

---

## Success Criteria

1. All E2E test scenarios have equivalent integration test coverage
2. Integration test suite runs in < 30 seconds
3. No regression in production bugs after E2E removal
4. CI pipeline time reduced by > 50%

---

## Questions for User

Before proceeding, please clarify:

1. **E2E Smoke Tests**: Do you want to keep ANY E2E tests as smoke tests for critical user journeys, or delete all after migration?

2. **Target Test Time**: What's the acceptable test execution time? Current E2E: ~3-5 min. Target integration: ~10-30 sec.

3. **Coverage Priority**: Should we prioritize speed (fewer comprehensive tests) or coverage (more granular tests)?

4. **API Mocking**: Should integration tests always mock APIs, or should some test real API integration?

5. **Specific Must-Keep E2E**: Are there specific test scenarios that MUST remain as E2E (e.g., real streaming, browser navigation)?

---

## Appendix: Test Categorization Detail

### CONVERT to Integration (9 files)

**chat.spec.ts**
- `should send a message and receive a response` -> ChatInput + ChatMessages tests
- `should not allow sending empty messages` -> ChatInput validation test
- `should show loading state while streaming` -> ChatMessages streaming test
- `should display timestamps next to tool names` -> ContentBlockRenderer test

**consecutive-streaming.spec.ts**
- `should stream text for both first and second response` -> ChatFlow integration test
- `should show incremental updates for second response` -> ChatFlow integration test

**content-rendering.spec.ts**
- Text blocks, thinking blocks, tool use, tool results -> ContentBlockRenderer test
- Expand/collapse, console errors, message persistence -> Component tests

**notifications.spec.ts**
- Speaker toggle button -> Already in SessionHeader.test.tsx (verified)

**progress.spec.ts**
- Animation during streaming -> Already in ChatMessages.test.tsx (verified)

**resume.spec.ts**
- Modal open/close, session list, resume -> SessionPicker.test.tsx

**ssh-hostname-modal.spec.ts**
- Modal show/hide, save hostname, VSCode open -> SessionHeader.test.tsx (mostly covered)

**stop-button.spec.ts**
- Show/hide/click stop button -> StopButton.test.tsx (extend with integration)

**url-detection.spec.ts**
- URL detection logic -> link-detector.test.ts (already covered)
- URL rendering in messages -> ContentBlockRenderer test

### KEEP as E2E (2 files)

**scroll-behavior.spec.ts**
- Requires real scroll position tracking (`scrollHeight`, `scrollTop`)
- JSDOM doesn't support real scroll behavior
- Critical UX feature worth E2E coverage

**tab-close-cleanup.spec.ts**
- Requires real `pagehide` event
- Tests actual network cleanup requests
- Heartbeat timing requires real browser

### DELETE (1 file)

**session-init.spec.ts**
- Tests app loads without errors
- Implicitly tested by every other test
- No value in dedicated E2E for this

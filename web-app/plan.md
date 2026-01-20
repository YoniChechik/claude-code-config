# E2E Test Plan: Real AI Response Test

## Executive Summary

Create an e2e test using Playwright that sends a real prompt to Claude (no mocks) and verifies receipt of an actual response. This test validates the complete end-to-end flow: UI → API → Claude CLI → streaming response → UI rendering. Single PR implementation.

## Current State

- **Framework**: Playwright with chromium browser
- **Config**: `playwright.config.ts`, tests run against `http://localhost:6379`
- **Existing Tests**: `/e2e/chat.spec.ts` contains multiple tests (send message, empty messages, loading state, persistence, tool calling)
- **Architecture**: Next.js app with:
  - Frontend: React components handle chat UI and stream processing
  - Backend: `/api/commands` route streams responses via Claude CLI
  - Claude CLI: Called directly (no API key needed), yields streaming events
  - Session management: Validates window ownership, tracks messages

## Target State

New test file `/e2e/real-response.spec.ts` that:
1. Navigates to app homepage
2. Types "hi" in chat input
3. Clicks send button
4. Waits for actual Claude response (not mock)
5. Verifies response contains text content from real API call
6. Confirms response persists in UI

## Implementation Approach

### Architecture Decisions

**Why no mocks?**
- Real Claude CLI is invoked server-side in `/api/commands` route
- Mock interception would require intercepting fetch at browser level
- No sensible way to mock the subprocess spawning (`spawn('claude', ...)`)
- Tests should validate actual streaming and response parsing

**How it works:**
1. Playwright navigates to app
2. App loads → creates session → window ID generated
3. User types "hi" → sends to `/api/commands` POST
4. Backend: Claude CLI subprocess spawns, streams events
5. Frontend: Reads streaming response (SSE-like format), parses events
6. Response accumulated as `ContentBlock[]`, rendered as it arrives
7. Test waits for response to appear in DOM, verifies non-empty content

### Key Implementation Details

**Existing patterns to follow:**
- Use `page.locator()` for element selection (not `page.$()`
- Select "Send" button with `locator("button:has-text('Send')")`
- Wait for elements with `toBeVisible({ timeout: 20000 })`
- Target first chat pane: `page.locator("main > div > div").first()`
- Extract text content: `textContent()` method

**Response validation:**
- Claude's response appears in `div.bg-gray-100` or `div.bg-gray-800` (depending on dark mode)
- Response content is in `div.whitespace-pre-wrap` child element
- Must wait long enough for streaming to complete (20s timeout recommended)
- Verify `textContent()` is truthy and has length > 0

**Current test baseline:**
- `/e2e/chat.spec.ts` already tests basic flow
- Existing test waits for response with 20s timeout
- Our test should follow same patterns and timeouts

## Implementation Steps

**Phase 1: Create test file (Easy)**
- File: `/e2e/real-response.spec.ts`
- Copy test structure from `chat.spec.ts`
- Import Playwright test utilities: `import { test, expect } from "@playwright/test"`

**Phase 2: Implement core test steps (Easy)**
- Navigate to "/" (baseURL configured in `playwright.config.ts`)
- Wait for textarea/input to appear
- Get first chat pane locator
- Fill input with "hi", verify value set
- Click send button
- Wait for input to clear (indicates message sent)
- Verify user message "hi" appears in pane

**Phase 3: Implement response verification (Medium)**
- Locate Claude's response message (last `div.bg-gray-100` containing "Claude" label)
- Extract content div with `whitespace-pre-wrap` class
- Verify it's visible (20s timeout for streaming)
- Get textContent and verify non-empty
- Check length > 0

**Phase 4: Test naming and documentation (Easy)**
- Test name: "should send a real prompt and receive actual Claude response"
- Add comments explaining what makes it different from existing tests
- Document that this is a real e2e test (no mocks, uses actual Claude CLI)

## Testing Strategy

**Test execution:**
- Run with: `npm run test:e2e` or `npm run test:e2e:no-build`
- Server must be running with Claude CLI available in PATH
- API key not needed (uses claude CLI directly)
- Test requires ~10-30 seconds (Claude response time varies)

**Success criteria:**
- Test passes consistently (allow 2 retries for flakiness)
- Response text is non-empty and from real Claude
- Test times out if Claude doesn't respond (20s limit)
- Validates both streaming receipt and DOM rendering

**What makes it real:**
- No `page.route()` interception of fetch calls
- Claude subprocess actually spawns in backend
- No mocked streaming events
- Actual token streaming from Claude API

## Dependencies

- Existing: Playwright test framework, test infrastructure
- No new dependencies needed
- Requires: Claude CLI installed and working on test runner

## Risks & Mitigations

| Risk | Impact | Mitigation |
|------|--------|-----------|
| Claude API rate limits | Test fails intermittently | Use simple prompt "hi", retries built-in |
| Response time varies | Timing-sensitive failures | Set 20s timeout, match existing test patterns |
| Multiple test runs consume tokens | Token quota issues | Keep test simple (one test, not test suite) |
| Claude CLI not available | Test fails on CI/local | Assume CLI is setup; will fail clearly if missing |
| Streaming parsing fails | Response never appears in DOM | Existing code handles this; we verify it works |

## Difficulty Assessment

- **Phase 1**: Easy - straightforward file creation and imports
- **Phase 2**: Easy - follow existing test patterns exactly
- **Phase 3**: Medium - understanding streaming response DOM structure
- **Phase 4**: Easy - documentation and naming
- **Overall**: Easy-Medium - mostly pattern matching against existing tests

## Files to Modify

**New file:**
- `/home/ubuntu/.claude/web-app/e2e/real-response.spec.ts` - Complete test file

**Reference files (read-only):**
- `/home/ubuntu/.claude/web-app/e2e/chat.spec.ts` - Pattern reference
- `/home/ubuntu/.claude/web-app/playwright.config.ts` - Test config
- `/home/ubuntu/.claude/web-app/app/api/commands/route.ts` - Backend API
- `/home/ubuntu/.claude/web-app/lib/claude-client.ts` - Stream event types
- `/home/ubuntu/.claude/web-app/components/ChatPane.tsx` - Frontend streaming logic

## Success Metrics

- [x] Test file created and properly structured
- [ ] Test navigates app and loads chat interface
- [ ] Test sends "hi" and verifies user message appears
- [ ] Test waits for Claude response (real streaming)
- [ ] Test verifies response content is non-empty
- [ ] Test passes consistently with existing infrastructure
- [ ] Test demonstrates real e2e flow (no mocks)

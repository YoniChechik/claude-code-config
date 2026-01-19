# Playwright to Integration Test Migration - Breakdown Document

## Executive Summary

Migrate appropriate Playwright E2E tests to @testing-library/react integration tests to improve test execution speed while maintaining coverage. Currently have 12 E2E test files with ~50+ test cases that take significant time to run.

## Analysis of Current Test Suites

### E2E Tests (Playwright)
- **Location**: `e2e/` directory
- **Count**: 12 files, ~50+ test cases
- **Execution time**: Slow (requires full browser automation, server startup)
- **Dependencies**: Real Next.js server, browser instance, full app initialization

### Integration Tests (@testing-library/react)
- **Location**: `__tests__/` and `__tests__/components/`
- **Count**: ~17 files
- **Execution time**: Fast (renders components in isolation)
- **Patterns**: Mocked API calls, isolated component testing, Jest

## Test Categorization

### ✅ CAN BE CONVERTED (Priority: Convert these first)

#### 1. notifications.spec.ts (2 tests)
- **Why**: Tests only SessionHeader component behavior
- **Conversion**: Render SessionHeader, mock onToggleAudioNotifications
- **Estimated effort**: 1-2 hours
- **Pattern**: Similar to existing SessionHeader.test.tsx

#### 2. session-init.spec.ts (3 tests)
- **Why**: Tests loading states and error handling
- **Conversion**: Render main page component, mock session API
- **Estimated effort**: 2-3 hours
- **Pattern**: Mock fetch responses for different scenarios

#### 3. progress.spec.ts
- **Why**: Tests UI progress indicators
- **Conversion**: Render components with streaming state
- **Estimated effort**: 2-3 hours
- **Pattern**: Control streaming state via props

### ⚠️ HYBRID (Partial conversion possible)

#### 4. stop-button.spec.ts (8 tests)
- **Current**: Full E2E with real streaming
- **Can convert**: Button visibility, onClick behavior, UI state
- **Must stay E2E**: Actual stream cancellation behavior, server interaction
- **Approach**: Convert UI tests, keep 1-2 E2E smoke tests
- **Estimated effort**: 3-4 hours

#### 5. resume.spec.ts (4 tests)
- **Current**: Full flow with modal, session selection, message loading
- **Can convert**: Modal rendering, session list, selection logic
- **Must stay E2E**: End-to-end resume flow (1 comprehensive test)
- **Approach**: Convert component tests, keep 1 E2E integration test
- **Estimated effort**: 4-5 hours

#### 6. content-rendering.spec.ts
- **Current**: Tests various content types (text, code, tool use)
- **Can convert**: Individual content block rendering
- **Must stay E2E**: Complete message flow with real streaming
- **Approach**: Convert to ChatMessages component tests, keep 1-2 E2E
- **Estimated effort**: 5-6 hours

#### 7. url-detection.spec.ts
- **Current**: Tests URL detection and link rendering
- **Can convert**: Link detection logic, rendering
- **Must stay E2E**: Click behavior, external navigation
- **Approach**: Convert rendering tests, keep 1 E2E for navigation
- **Estimated effort**: 3-4 hours

### ❌ MUST STAY E2E (Critical user journeys)

#### 8. chat.spec.ts
- **Why**: Tests complete chat flow with real server interaction
- **Keep**: Full message send → stream → display flow
- **Note**: This is a critical smoke test for the core functionality
- **Possible optimization**: Reduce number of test cases, keep 2-3 key scenarios

#### 9. consecutive-streaming.spec.ts
- **Why**: Tests message ordering and causality with real streaming
- **Keep**: Real streaming ensures correct async behavior
- **Note**: Critical for preventing race conditions
- **Possible optimization**: Reduce test permutations

#### 10. scroll-behavior.spec.ts
- **Why**: Tests actual browser scroll behavior
- **Keep**: Real DOM scrolling cannot be reliably mocked
- **Note**: Browser-specific behavior
- **Possible optimization**: Consolidate related tests

#### 11. ssh-hostname-modal.spec.ts
- **Why**: Tests modal lifecycle, form submission, SSH detection
- **Keep**: Complex interaction flow best tested E2E
- **Note**: Involves server-side SSH detection
- **Possible optimization**: Some modal rendering could be extracted

#### 12. tab-close-cleanup.spec.ts
- **Why**: Tests browser tab close events and cleanup
- **Keep**: Requires real browser events
- **Note**: Cannot mock browser lifecycle events
- **Possible optimization**: None - this is already minimal

## Migration Strategy

### Phase 1: Simple Component Tests (Week 1)
**Goal**: Convert straightforward UI component tests

1. ✅ notifications.spec.ts → SessionHeader integration tests
   - Test audio button toggle
   - Test button visibility
   - Mock API calls

2. ✅ session-init.spec.ts → Page component tests
   - Test loading states
   - Test error handling
   - Mock session initialization

**Success Criteria**: 5 test files converted, E2E test time reduced by ~20%

### Phase 2: Complex Components (Week 2)
**Goal**: Convert components with more complex interactions

3. ⚠️ stop-button.spec.ts → StopButton component tests (expand existing)
   - Convert visibility, state, and onClick tests
   - Keep 1-2 E2E tests for actual cancellation

4. ⚠️ progress.spec.ts → Progress indicator component tests
   - Test different progress states
   - Mock streaming state

**Success Criteria**: Additional 10-15 integration tests, E2E reduced by ~30%

### Phase 3: Content & Rendering (Week 3)
**Goal**: Convert rendering logic tests

5. ⚠️ content-rendering.spec.ts → ChatMessages component tests
   - Test different content types
   - Test tool use rendering
   - Keep 1-2 E2E for full flow

6. ⚠️ url-detection.spec.ts → Link detection tests
   - Test URL detection logic
   - Test link rendering
   - Keep 1 E2E for navigation

**Success Criteria**: Content rendering fully covered by integration tests

### Phase 4: Session Management (Week 4)
**Goal**: Convert session-related tests

7. ⚠️ resume.spec.ts → SessionPicker component tests
   - Test modal rendering
   - Test session list
   - Test selection logic
   - Keep 1 comprehensive E2E test

**Success Criteria**: 90% of tests are fast integration tests, 10% critical E2E

### Phase 5: Optimization & Cleanup
**Goal**: Optimize remaining E2E tests

- Review E2E tests to keep (chat, consecutive-streaming, scroll, ssh-modal, tab-close)
- Consolidate duplicate test scenarios
- Add missing integration test coverage
- Update test documentation

**Success Criteria**: E2E test suite runs in <2 minutes, integration tests in <10 seconds

## Implementation Plan

### For Each Conversion:

1. **Analyze E2E test**
   - Identify what's being tested
   - Determine if it needs real browser/server
   - Find the component(s) involved

2. **Create integration test**
   - Set up component with necessary props
   - Mock API calls and external dependencies
   - Test the same scenarios as E2E

3. **Add test to __tests__/components/ or __tests__/**
   - Follow existing patterns (StopButton.test.tsx, SessionHeader.test.tsx)
   - Use describe blocks for organization
   - Mock fetch with jest.fn()

4. **Verify coverage**
   - Run integration test
   - Ensure same behavior is tested
   - Check code coverage

5. **Remove or consolidate E2E test**
   - If fully converted: delete E2E test
   - If hybrid: keep minimal E2E smoke test
   - Document what remains and why

### Testing Strategy

**Integration Tests (Fast - run on every commit)**
- Component rendering
- UI state management
- Event handling
- Props and callbacks
- Conditional rendering
- Error states

**E2E Tests (Slow - run before merge/deploy)**
- Critical user journeys
- Real streaming behavior
- Browser-specific features
- Multi-component integration
- Server communication
- Session management

## Risk Assessment

### Risks

1. **False confidence**: Integration tests might pass but E2E fails
   - **Mitigation**: Keep critical E2E tests, run both suites

2. **Mock drift**: Mocks diverge from real API behavior
   - **Mitigation**: Generate mocks from real API responses, review regularly

3. **Missing coverage**: Some edge cases only caught by E2E
   - **Mitigation**: Careful analysis during conversion, code coverage tools

4. **Behavior differences**: Component behaves differently in isolation
   - **Mitigation**: Test with realistic props and state, verify against E2E

5. **Time investment**: Conversion takes significant effort
   - **Mitigation**: Phased approach, prioritize high-value conversions

### Mitigations

- **Parallel testing**: Run both E2E and integration tests during transition
- **Incremental migration**: Convert one test file at a time
- **Code review**: Peer review each conversion
- **Coverage reports**: Track coverage throughout migration
- **Documentation**: Document what each test type covers

## Questions for User

Before proceeding, we need answers to:

1. **Coverage vs Speed tradeoff**: Are you willing to accept slightly less comprehensive coverage for much faster test execution?

2. **E2E smoke tests**: Which user journeys are absolutely critical to keep as E2E? (e.g., "user can send message and get response")

3. **Test execution time target**: What's acceptable? Current E2E might take 5-10 minutes, integration tests <30 seconds

4. **Mocking strategy**: Should we always mock API calls in integration tests, or sometimes test against real API?

5. **Maintenance priority**: Would you rather have comprehensive but slow tests, or fast tests that require more careful mocking?

6. **Existing test failures**: Are all current tests passing? Should we fix those first?

## Success Metrics

- **Test execution time**: Reduce from ~5-10 min to <2 min for E2E + <30s for integration
- **Test count**: 80-90% integration tests, 10-20% E2E tests
- **Coverage**: Maintain >80% code coverage
- **Developer experience**: Tests run quickly on save, fast feedback
- **CI/CD**: Faster pipeline, quicker feedback on PRs

## Estimated Timeline

- **Phase 1**: 1 week (simple components)
- **Phase 2**: 1 week (complex components)
- **Phase 3**: 1 week (content rendering)
- **Phase 4**: 1 week (session management)
- **Phase 5**: 3-5 days (optimization)

**Total**: 4-5 weeks for complete migration

## Recommendation

**START WITH**: Phase 1 (notifications + session-init) - these are clear wins with minimal risk. This will:
- Provide immediate test speed improvement
- Establish conversion patterns
- Build confidence in the approach
- Allow user to evaluate if this direction is correct

After Phase 1, reassess based on:
- Time saved
- Issues encountered
- User satisfaction
- Coverage maintained

---

## Next Steps

1. **User answers questions above**
2. **Review and approve this plan**
3. **Begin Phase 1 conversions**
4. **Iterate based on learnings**

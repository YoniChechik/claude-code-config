# Testing Guide

This document describes the testing setup for the ccweb project.

## Test Framework

- **Jest**: Unit testing framework
- **@testing-library/react**: React component testing utilities
- **Playwright**: E2E testing (existing)

## Running Tests

```bash
# Run all unit tests
npm test

# Run tests in watch mode
npm run test:watch

# Run tests with coverage report
npm run test:coverage

# Run E2E tests
npm run test:e2e
```

## Test Structure

Tests are located in the `__tests__/` directory:

```
__tests__/
├── test-utils.ts           # Shared test utilities and mocks
├── utils.test.ts           # lib/utils.ts tests
├── cd-tracker.test.ts      # lib/cd-tracker.ts tests
├── autosuggest.test.ts     # lib/autosuggest.ts tests
├── claude-client.test.ts   # lib/claude-client.ts tests
├── session-manager.test.ts # lib/session-manager.ts tests
├── session-storage.test.ts # lib/session-storage.ts tests (existing)
└── symlink-manager.test.ts # lib/symlink-manager.ts tests (existing)
```

## Coverage

Current test coverage focuses on core library functionality:

| Module | Coverage |
|--------|----------|
| utils.ts | 100% |
| cd-tracker.ts | 100% |
| session-manager.ts | 100% |
| autosuggest.ts | 98.55% |
| symlink-manager.ts | 92.3% |
| session-storage.ts | 52.27% |

### Coverage Goals

The project follows a pragmatic approach to test coverage:

- **Core utilities**: 100% coverage (utils, cd-tracker, session-manager)
- **Business logic**: >90% coverage (autosuggest, symlink-manager)
- **Data access**: >50% coverage (session-storage)
- **Complex integrations**: E2E tested (claude-client streaming)
- **React components**: E2E tested (Playwright)
- **API routes**: E2E tested (Playwright)

## Test Utilities

The `test-utils.ts` file provides:

- `mockClaudeStream()`: Mock Claude API streaming responses
- `asyncFromSync()`: Convert sync generators to async
- `collectAsyncGenerator()`: Collect all async generator values
- `mockSpawn()`: Mock child_process.spawn for process testing
- `nextTick()`, `delay()`: Async timing utilities

## Writing Tests

### Unit Tests

Follow existing patterns in the test files:

```typescript
import { functionToTest } from "../lib/module";

describe("module", () => {
  describe("functionToTest", () => {
    it("should handle typical case", () => {
      const result = functionToTest(input);
      expect(result).toBe(expected);
    });

    it("should handle edge case", () => {
      const result = functionToTest(edgeInput);
      expect(result).toBe(edgeExpected);
    });

    it("should fail on invalid input", () => {
      expect(() => functionToTest(invalid)).toThrow();
    });
  });
});
```

### Fail-Fast Testing

The codebase follows fail-fast principles (see `CLAUDE.md`):

- Tests should fail immediately when expectations aren't met
- Use direct assertions without defensive checks
- Let invalid states throw errors rather than returning nulls
- Test error cases explicitly

### Async Tests

Use async/await for testing async code:

```typescript
it("should handle async operation", async () => {
  const result = await asyncFunction();
  expect(result).toBe(expected);
});
```

## Mocking

### Environment Variables

```typescript
beforeEach(() => {
  process.env.HOME = tempDir;
});

afterEach(() => {
  delete process.env.HOME;
});
```

### File System

Tests use real temp directories for file system operations:

```typescript
import { promises as fs } from "fs";
import { tmpdir } from "os";
import { join } from "path";

let tempDir: string;

beforeEach(async () => {
  tempDir = await fs.mkdtemp(join(tmpdir(), "test-"));
});

afterEach(async () => {
  await fs.rm(tempDir, { recursive: true, force: true });
});
```

## Future Work

Areas for additional test coverage:

1. API route testing (app/api/**)
2. React component unit tests
3. Error handling flows
4. Network failure scenarios
5. ClaudeClient streaming (currently E2E tested only)

## CI/CD Integration

Tests should be run in CI/CD pipelines:

```yaml
- name: Run tests
  run: npm test

- name: Check coverage
  run: npm run test:coverage
```

## Troubleshooting

### Tests Hanging

- Check for missing `mockProcess.emit("close")` in Claude client tests
- Verify timeouts in async operations

### File System Issues

- Ensure temp directories are cleaned up in `afterEach`
- Check that `process.env.HOME` is properly set for tests

### Coverage Thresholds

If tests fail due to coverage thresholds, verify:
- New code has adequate test coverage
- Coverage thresholds in `jest.config.js` are appropriate

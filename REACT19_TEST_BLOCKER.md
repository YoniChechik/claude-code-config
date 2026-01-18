# React 19 Testing Compatibility Blocker

## Issue

Cannot run Jest + @testing-library/react tests with React 19 due to incompatibility between:
- React 19.2.3
- @testing-library/react 16.3.1
- react-dom/test-utils

## Error

```
TypeError: React.act is not a function
  at exports.act (node_modules/react-dom/cjs/react-dom-test-utils.production.js:20:16)
  at node_modules/@testing-library/react/dist/act-compat.js:46:25
```

## Root Cause

In React 19, `act` is only exported from the 'react' package, not from 'react-dom/test-utils'.
However, @testing-library/react still tries to import act from react-dom/test-utils for backwards compatibility.

## Attempted Fixes

1. ✗ Polyfill `global.React.act` in jest.setup.js
2. ✗ Update @testing-library/react to latest
3. ✗ Mock React module to inject act
4. ✗ Patch ReactDOM.act directly

None of these worked because the issue is deep in the dependency chain.

## Options

### Option 1: Downgrade to React 18 (RECOMMENDED)
- Downgrade react + react-dom to 18.x
- All tests will work immediately
- Trade-off: No React 19 features

### Option 2: Wait for @testing-library/react update
- Check for @testing-library/react v17+ with React 19 support
- Currently no stable release exists
- May take weeks/months

### Option 3: Skip integration tests for now
- Continue with only E2E Playwright tests
- Revisit when React 19 compatibility is resolved
- Defeats purpose of this refactoring

## Recommendation

**Downgrade to React 18** for now. The project doesn't appear to use React 19-specific features, and having working integration tests is more valuable than React 19.

```bash
npm install react@18 react-dom@18
```

After downgrade, all existing SessionHeader.test.tsx tests should pass, and new StopButton.test.tsx will work.

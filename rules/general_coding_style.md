# General Coding Guidelines

## FAIL FAST - Critical Rule

**NEVER hide errors. Let code fail immediately and loudly when something is wrong.**

### Core Principles

- Never mask errors with default values or silent catches
- Let code crash during development to discover bugs early
- Don't check for conditions that should always be true
- Raise exceptions instead of returning error codes or sentinel values
- Use as few try/catch blocks as possible; let exceptions propagate naturally

**Why**: Defensive programming delays bug discovery. We want crashes in development, not silent failures in production.

### FORBIDDEN patterns that hide bugs

These are conceptual anti-patterns that apply across languages:

- Checking if attributes/keys exist before accessing them → Access directly and let it fail
- Using fallback defaults when accessing collections → Fail on missing items
- Unnecessary type checks for expected types → Just call the method and let it fail
- Checking collection size before accessing elements → Just access and let it fail
- Catch-log-continue pattern → `try { ... } catch { log.error(); continue; }` hides failures
- Silent failure catches → `try { ... } catch { /* do nothing */ }` - never do this
- Sentinel values → Never return `-1`, `null`, or empty string to indicate errors, raise exceptions instead
- Default-or pattern that hides falsy values → Use explicit null checks when needed

## Code Organization

- **Modular functions**: Keep functions small (~50 lines max) and focused on single responsibility
- **Top-down organization**: Main functions first, helper functions after
- **Avoid nested ifs**: Prefer early returns and guard clauses to reduce nesting depth
- **No copy-paste**: Split duplicated code into reusable functions

## Backward Compatibility

- **NO backward compatibility** - Delete unused code completely
- Exceptions: user explicitly requests OR public external APIs

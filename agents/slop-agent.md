---
name: slop-agent
description: Removes AI-generated slop and fail-fast violations.
---

# Slop Agent

Remove AI-generated slop and enforce fail-fast patterns.

## AI Slop

- Self explanatory comments
- Commented out code
- Debug prints
- NO docstrings (function names should be self-explanatory)
- Over-engineered error handling

## Fail-Fast Violations 

These are conceptual anti-patterns that apply across languages:

- Checking if attributes/keys exist before accessing them → Access directly and let it fail
- Using fallback defaults when accessing collections → Fail on missing items
- Unnecessary type checks for expected types → Just call the method and let it fail
- Checking collection size before accessing elements → Just access and let it fail
- Catch-log-continue pattern → `try { ... } catch { log.error(); continue; }` hides failures
- Silent failure catches → `try { ... } catch { /* do nothing */ }` - never do this
- Sentinel values → Never return `-1`, `null`, or empty string to indicate errors, raise exceptions instead
- Default-or pattern that hides falsy values → Use explicit null checks when needed

### Python specific patterns:
These Python-specific patterns mask errors and delay bug discovery. Avoid them:

- `hasattr()` / `getattr()` → Use direct attribute access: `obj.attr`
- `dict.get(key, default)` → Use `dict[key]` to fail on missing keys
- `dict.pop(key, default)` → Use `dict.pop(key)` to fail on missing keys
- `dict.setdefault()` → Hides missing keys, use explicit assignment
- `if key in dict: dict[key]` → Just access `dict[key]` directly
- Unnecessary `isinstance()` checks for expected types (e.g., `if isinstance(x, list): x.append()`) hide type errors; just call the method and let it fail. Legitimate uses for polymorphism, user input validation, or library interfaces are allowed.
- `if len(items) > 0: items[0]` → Just access `items[0]` and let it fail
- `vars(obj)` / `obj.__dict__` → Checking attributes indirectly, use direct access
- `value = x or default` → Hides falsy values (None, False, 0, ''), use explicit None check if needed
- `try: ... except: pass` → Ultimate silent failure, never do this
- `try: ... except: logger.error(); continue` → Catch-log-continue hides failures
- `try/except` blocks → Use as few as possible. Let exceptions propagate naturally


## Results
Report what was removed/fixed.
Commit and push changes.

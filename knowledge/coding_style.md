# Python Coding Style Guide

This document defines the coding conventions for the project.

## FAIL FAST - Critical Rule

**NEVER hide errors. Let code fail immediately and loudly when something is wrong.**

### FORBIDDEN patterns that hide bugs

These patterns mask errors and delay bug discovery. Avoid them:

- `hasattr()` / `getattr()` → Use direct attribute access: `obj.attr`
- `dict.get(key, default)` → Use `dict[key]` to fail on missing keys
- `dict.pop(key, default)` → Use `dict.pop(key)` to fail on missing keys
- `dict.setdefault()` → Hides missing keys, use explicit assignment
- `if key in dict: dict[key]` → Just access `dict[key]` directly
- Unnecessary `isinstance()` checks for expected types (e.g., `if isinstance(x, list): x.append()`) hide type errors; just call the method and let it fail. Legitimate uses for polymorphism, user input validation, or library interfaces are allowed.
- `if len(items) > 0: items[0]` → Just access `items[0]` and let it fail
- `vars(obj)` / `obj.__dict__` → Checking attributes indirectly, use direct access
- `value = x or default` → Hides falsy values (None, False, 0, ''), use explicit None check if needed
- Sentinel values → Never return `-1`, `None`, or `''` to indicate errors, raise exceptions instead
- Catch-log-continue → `try: ... except: logger.error(); continue` hides failures
- `try: ... except: pass` → Ultimate silent failure, never do this
- `try/except` blocks → Use as few as possible. Let exceptions propagate naturally

**Why**: Defensive programming delays bug discovery. We want crashes in development, not silent failures in production.

## General Conventions

- **Type annotations**: Always annotate functions/classes
- **Modern Python**: Use `list` over `List`, `dict` over `Dict`, `x | None` over `Optional[x]`
- **Numpy types**: `npt.NDArray[np.floating]` for floats, `npt.NDArray[np.integer]` for integers
- **No copy-paste**: Split code into functions, return multiple values as dataclasses
- **Modular functions**: Keep functions small (~50 lines max) and focused on single responsibility
- **Top-down code organization**: main functions first, helpers after
- **Avoid nested ifs**: Prefer early returns and `if not: continue` style to reduce nesting depth
- **Private functions and classes**: Start with `_`
- **No docstrings**: Function names should be self-explanatory. Comments only on hard logic
- **No relative imports**: Always use absolute imports (e.g., `from some_package.utils import ...`, not `from .utils import ...`)
- **No lint ignore rules**: Never add rules to `lint.ignore` in pyproject.toml. Fix the code instead
- **No noqa comments**: Don't use `# noqa` to suppress warnings, except for undefined types from external libraries (e.g., `# type: ignore[import-untyped]`)
- **String formatting**: Always prefer f-strings over `.format()` or `%` formatting (e.g., `f"Hello {name}"`, not `"Hello {}".format(name)`)
- **Runnable Scripts**: Shebang with `#!/usr/bin/env -S uv run --script`
- Use dataclasses for multiple return values from functions

## Naming Conventions

- Files/directories: lowercase_with_underscores
- Image dimensions: explicit hw/wh suffix (img_hw for height,width)
- Image formats: rgb/bgr/gray suffix for color space

## Dependencies

- Prefer pathlib over os.path, opencv over PIL
- Leverage existing libraries (torch, numpy, scipy, opencv) rather than reimplementing
- Suggest package installation for known solutions

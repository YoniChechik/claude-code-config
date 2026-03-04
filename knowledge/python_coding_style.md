# Python Coding Style Guide

## Python-Specific FAIL FAST Patterns

### FORBIDDEN patterns in Python

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

## Type Annotations

- **Always annotate** functions and classes
- **Modern Python syntax**: Use `list` over `List`, `dict` over `Dict`, `x | None` over `Optional[x]`
- **Numpy types**: `npt.NDArray[np.floating]` for floats, `npt.NDArray[np.integer]` for integers

## Python Conventions

- **Private members**: Start with `_` for private functions and classes
- **No docstrings**: Function names should be self-explanatory. Comments only on hard logic. Don't add module docstrings or function docstrings
- **No relative imports**: Always use absolute imports (e.g., `from some_package.utils import ...`, not `from .utils import ...`)
- **No lint ignore rules**: Never add rules to `lint.ignore` in pyproject.toml. Fix the code instead
- **No noqa comments**: Don't use `# noqa` to suppress warnings, except for undefined types from external libraries (e.g., `# type: ignore[import-untyped]`)
- **String formatting**: Always prefer f-strings over `.format()` or `%` formatting (e.g., `f"Hello {name}"`, not `"Hello {}".format(name)`)
- **Multiple return values**: Use dataclasses for functions returning multiple values

## Naming Conventions

- Files/directories: lowercase_with_underscores
- Image dimensions: explicit hw/wh suffix (img_hw for height,width)
- Image formats: rgb/bgr/gray suffix for color space

## Dependencies

- Prefer pathlib over os.path, opencv over PIL
- Leverage existing libraries (torch, numpy, scipy, opencv) rather than reimplementing
- Suggest package installation for known solutions

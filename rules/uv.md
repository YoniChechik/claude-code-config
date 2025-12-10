---
paths: **/*.py
---

# UV Package Manager Guide

UV is a fast Python package manager and project manager, serving as a drop-in replacement for pip, pip-tools, and virtualenv.

## Core Commands

### Project Setup
```bash
uv sync                           # Install all default AND dev dependencies from pyproject.toml
```

### Running Commands
```bash
uv run python script.py           # Run Python with project dependencies
```

### Adding Dependencies
```bash
uv add package-name               # Add to [project.dependencies]
uv add --dev package-name         # Add to [dependency-groups.dev]
```

### Testing
```bash
uv run pytest                     # Run all tests
uv run pytest -n auto             # Parallel execution
uv run pytest -m "not integration" # Skip integration tests
uv run pytest -m "not slow"       # Skip slow tests
```

### Code Quality (handled by agents, but for reference)
```bash
uv run ruff format file.py        # Format code
uv run ruff check file.py         # Lint code
uv run mypy --strict file.py      # Type check
```

## Important: DO NOT Use `uv pip`

**❌ NEVER use:**
```bash
uv pip install package
uv pip install -e .
uv pip list
```

**✅ Instead use:**
```bash
uv add package                     # Add dependencies
uv sync                            # Sync environment
uv run python -c "..."             # Run with environment
```

## Important: Always Use `uv run python` with PYTHONPATH

When working with multiple clones of a repo sharing one venv, always prepend `PYTHONPATH=.` to ensure the current clone's modules are used.

**❌ NEVER use:**
```bash
python script.py
python -m module.name
uv run python script.py
```

**✅ ALWAYS use:**
```bash
PYTHONPATH=. uv run python script.py
PYTHONPATH=. uv run python -m module.name
PYTHONPATH=. uv run pytest path/to/test.py
```

This ensures the current directory's modules take precedence over any `.pth` file pointing to other clones.

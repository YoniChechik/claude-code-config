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

## Important: Anty petterns

### **NEVER use bare `python`**
```bash
python ...
python3 ...
```

INSTEAD- we have `uv run python ...`

### **NEVER use `pip`**
```bash
uv pip ...
pip ...
python -m pip ...
uv run python -m pip ...
```

INSTEAD- we have `uv add` and `uv sync`

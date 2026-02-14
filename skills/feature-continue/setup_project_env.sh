#!/usr/bin/env bash

# Setup development environment for the current project
# Detects project type and runs appropriate setup commands

set -e

# Python project: check for pyproject.toml
if [ -f "pyproject.toml" ]; then
    echo "Detected Python project (pyproject.toml found)"
    echo "Running: uv venv"
    uv venv
fi

# npm project: check for package-lock.json
if [ -f "package-lock.json" ]; then
    echo "Detected npm project (package-lock.json found)"
    echo "Running: npm install"
    npm install
fi

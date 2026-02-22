#!/usr/bin/env bash
# Detects project type and runs appropriate setup commands

set -e

if [ -f "pyproject.toml" ]; then
    echo "Detected Python project (pyproject.toml found)"
    echo "Running: uv venv"
    uv venv
fi

if [ -f "package-lock.json" ]; then
    echo "Detected npm project (package-lock.json found)"
    echo "Running: npm install"
    npm install
fi

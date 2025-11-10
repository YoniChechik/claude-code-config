# GitHub CLI Usage Guidelines

Guidelines for safe and responsible use of GitHub CLI (`gh`) in this project.

## Core Principle

**NEVER bypass repository permissions or protections with gh CLI.**

All PRs must follow the standard approval process, even if you have admin access.

## Forbidden Practices

❌ **NEVER** use `--admin` flag to bypass PR approvals
❌ **NEVER** use administrator permissions to override branch protections
❌ **NEVER** force-merge without required approvals
❌ **NEVER** disable or bypass status checks
❌ **NEVER** use force push to main/master branches

All other operations with `gh` are allowed as long as they respect repository rules.

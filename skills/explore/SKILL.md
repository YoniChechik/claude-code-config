---
name: "explore"
description: "Research a topic or feature from both sides: explore the existing codebase (patterns, architecture, related files, dependencies, integration points) AND search the web for common solutions, alternatives, libraries, and blog posts about the underlying problem. Use before or during planning, or whenever unfamiliar territory needs research before deciding an approach."
argument-hint: "[topic or feature-description]"
---

# Explore

Research a topic from both sides — what already exists in this codebase, and
what already exists in the world — so a decision can be made with real
information instead of a guess.

## Topic from user input
"$ARGUMENTS"

## Process

### Codebase side
- Explore existing code patterns and architecture relevant to the topic.
- Identify related files and components.
- Understand dependencies and integration points.

### Web side
- Search the web for common solutions and alternatives to the underlying
  problem — not just this codebase's own history.
- Include libraries/packages that already solve this or a closely related
  problem.
- Include blog posts or writeups discussing the problem, so real-world
  tradeoffs surface instead of getting rediscovered from scratch.

### Report
Summarize both sides together: what already exists in the codebase that's
relevant, and what's out there (approaches, libraries, tradeoffs) — enough
for the caller to make an informed decision. Cite `file:line` for codebase
findings and URLs for web findings.

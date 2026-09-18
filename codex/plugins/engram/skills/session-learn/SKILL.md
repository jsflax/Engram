---
name: session-learn
description: Review the current session and save durable insights to Engram when the user explicitly asks for session learning.
allowed-tools: mcp__memory__recall, mcp__memory__remember, mcp__memory__update, mcp__memory__connect, mcp__memory__graph
---

# Learn from This Session

Review the visible session for useful debugging causes, architecture decisions, workflow discoveries, and non-obvious gotchas. Skip intermediate attempts, ordinary edit summaries, and facts already documented well enough for the requested purpose. A few durable insights are usually enough.

Scope each insight to its subject: knowledge about Lattice belongs to `Lattice` even if discovered while working on Engram; general language or workflow knowledge belongs to `global`. Use established project names, never guesses from directory basenames.

Search with `mcp__memory__recall` for the main candidate topics. Prefer updating an existing memory over duplicating the same insight. Use `mcp__memory__remember` for new atomic facts, with concise content, topic, importance, and an existing parent UUID when appropriate. Connect records only when their content supports the relationship.

Use UUIDs returned by the memory tools. Do not store private credentials or raw transcripts. Report the confirmed new or updated memories and their UUIDs, or say that no new durable insight was found. This skill handles the requested manual review; it does not configure automatic learner hooks.

---
name: remember
description: Store or refine a memory in Engram when the user asks to remember information for future sessions.
allowed-tools: mcp__memory__recall, mcp__memory__remember, mcp__memory__connect, mcp__memory__update, mcp__memory__graph
---

# Remember in Engram

Use the memory MCP tools to save the information requested by the user.

- Scope the memory by its subject: a known project's facts belong to that project; cross-project preferences and general patterns belong to `global`. Use an explicit project name or established mapping, never a working-directory basename guess.
- Search with `mcp__memory__recall` before storing. Reuse an exact existing memory; use `mcp__memory__update` when the request refines that same fact. Keep genuinely different facts separate.
- Use `mcp__memory__remember` for new information. Store one concept per memory with a useful topic and appropriate importance. Use `expires_in_days` for temporary context and `parent_id` for a detail belonging to an existing hub.
- Connect related memories when the relationship is supported by their content. Reuse UUIDs returned by the tools; do not invent IDs or infer a relationship from similarity alone.

Report what was stored, updated, or already present, with its UUID. Do not claim a write succeeded unless the tool confirms it.

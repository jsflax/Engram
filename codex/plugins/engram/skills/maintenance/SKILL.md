---
name: maintenance
description: Consolidate redundant Engram memories and organize topics within the scope of an explicit memory-maintenance request.
allowed-tools: mcp__memory__stats, mcp__memory__list_topics, mcp__memory__find_clusters, mcp__memory__detect_communities, mcp__memory__recall, mcp__memory__graph, mcp__memory__consolidate, mcp__memory__organize, mcp__memory__merge, mcp__memory__connect
---

# Maintain Engram Memories

Work within the requested project, topic, or memory set. Use established project names based on the subject, not a directory basename.

Start with `mcp__memory__stats` and `mcp__memory__list_topics`. Use `mcp__memory__find_clusters` to find possible redundancy and `mcp__memory__detect_communities` for useful groups. Read the full candidate records with recall or graph before deciding; similar previews do not establish duplication.

- Use `mcp__memory__merge` or `mcp__memory__consolidate` only for records that repeat the same knowledge. Write a concise combined statement preserving distinct useful facts and the highest relevant importance.
- Use `mcp__memory__organize` to create a meaningful hub for related records that should remain separate.
- Connect resulting records to relevant existing hubs or related facts using UUIDs returned by Engram.

Avoid changing unrelated projects or erasing differing viewpoints as duplicates. Re-read the affected records and summary counts to verify the result. Report the specific changes and UUIDs; if the memories were already well organized, say so.

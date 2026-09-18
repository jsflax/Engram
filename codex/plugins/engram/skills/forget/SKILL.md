---
name: forget
description: Remove selected Engram memories when the user explicitly asks to forget or delete them.
allowed-tools: mcp__memory__recall, mcp__memory__forget, mcp__memory__graph
---

# Forget an Engram Memory

Identify the requested memory by its UUID or by searching the user's description with `mcp__memory__recall`. Memory IDs are UUID strings, not numeric IDs. Use only IDs returned by Engram or explicitly supplied by the user.

Inspect the target with `mcp__memory__graph` to verify its content and relevant connections. If the user has already clearly selected the target and requested its removal, call `mcp__memory__forget` for that UUID. If the target is ambiguous, present concise candidate summaries and UUIDs and resolve which ones the user wants removed before changing them.

Delete only the selected memories. If the user actually wants a correction, explain that updating the memory is the appropriate operation. Report the tool-confirmed result, preserving any distinction the server makes between deletion and tombstoning.

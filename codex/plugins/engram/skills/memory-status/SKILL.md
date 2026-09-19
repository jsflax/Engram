---
name: memory-status
description: Show Engram memory counts, project and topic distribution, recent activity, active tasks, and stored episodes.
allowed-tools: mcp__memory__stats, mcp__memory__list_topics, mcp__memory__timeline, mcp__memory__list_tasks, mcp__memory__list_episodes
---

# Engram Memory Status

Use the memory MCP tools to report the requested memory scope. Apply an explicit project filter when requested; do not derive one from a directory name.

Read `mcp__memory__stats` and `mcp__memory__list_topics`. When relevant to the request, also read recent `mcp__memory__timeline`, `mcp__memory__list_tasks`, and `mcp__memory__list_episodes` results. Independent reads can run together. Use supported limits to keep recent lists concise.

Present a compact summary of counts, major projects/topics, recent activity, and active tasks or episodes. Report unavailable tools or failed reads as unavailable, not as zero counts. If a topic appears crowded, mention it as a possible maintenance candidate; a status request does not itself request consolidation or deletion.

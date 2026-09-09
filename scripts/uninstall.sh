#!/bin/bash
set -e

INSTALL_DIR="$HOME/.claude/bin"

echo "Uninstalling memory server..."

# Remove only Engram-owned Codex hooks before deleting their installer. The
# helper deliberately preserves learned state, backups, and unrelated hooks.
if [ -f "$INSTALL_DIR/codex/install_codex_support.sh" ]; then
    if bash "$INSTALL_DIR/codex/install_codex_support.sh" uninstall; then
        rm -rf "$INSTALL_DIR/codex"
    else
        echo "Keeping Codex installer payload so removal can be retried."
    fi
fi

# Deregister from Claude Code
env -u CLAUDECODE claude mcp remove memory 2>/dev/null || true

# Remove binaries and bundles
rm -f "$INSTALL_DIR/memory"
rm -f "$INSTALL_DIR/memory-hooks"
rm -rf "$INSTALL_DIR/Engram_EngramKit.bundle"
rm -rf "$INSTALL_DIR/swift-transformers_Hub.bundle"
rm -rf "$INSTALL_DIR/SwiftLM_SwiftLM.bundle"

# Remove agent definitions
AGENTS_DIR="$HOME/.claude/agents"
rm -f "$AGENTS_DIR/memory-maintenance.md"
rm -f "$AGENTS_DIR/session-learner.md"

# Remove hooks and permissions from settings.json
SETTINGS_FILE="$HOME/.claude/settings.json"
if [ -f "$SETTINGS_FILE" ] && command -v jq &>/dev/null; then
    jq 'del(.hooks.SessionStart, .hooks.UserPromptSubmit, .hooks.Stop, .hooks.PostToolUseFailure, .hooks.PreCompact, .hooks.SessionEnd)
        | if .hooks == {} or .hooks == null then del(.hooks) else . end
        | .permissions.allow = ([.permissions.allow[]? | select(. != "mcp__memory__*")])
        | if .permissions.allow == [] then del(.permissions.allow) else . end
        | if .permissions == {} or .permissions == null then del(.permissions) else . end' \
        "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp"
    mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
    # Remove file if it's just an empty object
    if [ "$(jq 'length' "$SETTINGS_FILE")" = "0" ]; then
        rm -f "$SETTINGS_FILE"
        echo "Removed empty $SETTINGS_FILE"
    else
        echo "Removed hooks and permissions from $SETTINGS_FILE"
    fi
fi

# Remove memory instructions from CLAUDE.md
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
if [ -f "$CLAUDE_MD" ]; then
    # Remove the Memory section (from "# Memory" to next top-level heading or EOF)
    awk '
        /^# Memory$/ { skip=1; next }
        /^# / && skip { skip=0 }
        !skip { print }
    ' "$CLAUDE_MD" > "$CLAUDE_MD.tmp"
    # Clean up any trailing blank lines
    sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$CLAUDE_MD.tmp" > "$CLAUDE_MD"
    rm -f "$CLAUDE_MD.tmp"
    # Remove file if empty
    [ -s "$CLAUDE_MD" ] || rm -f "$CLAUDE_MD"
    echo "Removed memory instructions from $CLAUDE_MD"
fi

echo "Done! Server removed."
echo "Note: Database preserved at ~/.claude/memory.sqlite"
echo "To also delete memories: rm ~/.claude/memory.sqlite*"

#!/bin/bash
# Shared by the shell installer and GUI updater. Optional Codex support must
# never prevent Claude's existing installation from completing. The delegated
# installer skips all writes when an Engram plugin is configured, even disabled;
# plugin-absent recipients retain the standalone setup. Explicit uninstall is
# the owned-only legacy migration and preserves queue/cursor/runtime data.
set -eu

ACTION="${1:-install}"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"

case "$ACTION" in
    install|uninstall) ;;
    *) echo "Usage: $0 [install|uninstall]" >&2; exit 2 ;;
esac

if [ "$ACTION" = install ] && [ ! -d "$CODEX_DIR" ] && \
    ! command -v codex >/dev/null 2>&1 && \
    [ ! -d /Applications/Codex.app ] && [ ! -d "$HOME/Applications/Codex.app" ]; then
    echo "Codex session learner: skipped (Codex is not installed)."
    exit 0
fi

CODEX_PYTHON=""
try_python() {
    [ -n "$1" ] && [ -x "$1" ] || return 1
    local resolved_interpreter
    if resolved_interpreter="$("$1" -c 'import sys; sys.exit(1) if sys.version_info < (3, 11) else print(sys.executable)' 2>/dev/null)"; then
        CODEX_PYTHON="$resolved_interpreter"
        return 0
    fi
    return 1
}

# Resolve to an absolute, concrete interpreter; launchd/app environments do
# not inherit the interactive shell's PATH or pyenv initialization.
if [ -n "${ENGRAM_CODEX_PYTHON:-}" ]; then
    try_python "$ENGRAM_CODEX_PYTHON" || true
else
    for candidate in "$(command -v python3 2>/dev/null || true)" \
        /opt/homebrew/bin/python3 /usr/local/bin/python3 \
        /opt/homebrew/opt/python@3.14/bin/python3.14 \
        /opt/homebrew/opt/python@3.13/bin/python3.13 \
        /opt/homebrew/opt/python@3.12/bin/python3.12 \
        /opt/homebrew/opt/python@3.11/bin/python3.11 \
        "$HOME"/.pyenv/versions/*/bin/python3 /usr/bin/python3; do
        if try_python "$candidate"; then break; fi
    done
fi

if [ -z "$CODEX_PYTHON" ]; then
    echo "Codex session learner: skipped (Python 3.11+ required). Install Python, then rerun this installer; ENGRAM_CODEX_PYTHON may name an interpreter." >&2
    [ "$ACTION" = install ] || exit 1
    exit 0
fi

INSTALL_ARGS=("$ACTION" --source-dir "$SOURCE_DIR" --python "$CODEX_PYTHON" --codex-home "$CODEX_DIR")
if [ "$ACTION" = install ]; then
    INSTALL_ARGS+=(--memory-command "$HOME/.claude/bin/memory")
fi
if ! "$CODEX_PYTHON" "$SOURCE_DIR/install_codex_learner.py" "${INSTALL_ARGS[@]}"; then
    echo "Codex session learner: $ACTION failed; existing Engram installation is retained. Rerun this installer after resolving the error above." >&2
    exit 1
fi

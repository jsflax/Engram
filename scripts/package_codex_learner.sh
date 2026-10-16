#!/bin/bash
# Produce the same self-contained payload for source, tarball, and GUI installs.
set -eu
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINATION="${1:?Usage: package_codex_learner.sh DESTINATION}"
mkdir -p "$DESTINATION/codex_learner"
for file in install_codex_support.sh install_codex_learner.py codex_learner.py \
    codex_learner/__init__.py codex_learner/transcript.py codex_learner/runner.py \
    codex_learner/memory_proxy.py \
    codex_learner/learner_prompt.md; do
    cp "$SOURCE_DIR/$file" "$DESTINATION/$file"
done
# The app UI and Codex skill consume the exact same bounded health read model.
# Keep classification in one source instead of maintaining a Swift fork.
cp "$SOURCE_DIR/../codex/plugins/engram/skills/hook-status/scripts/hook_status.py" "$DESTINATION/hook_status.py"

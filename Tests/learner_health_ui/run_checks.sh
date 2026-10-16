#!/bin/bash
set -eu
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${1:?Usage: run_checks.sh ABSOLUTE_SCRATCH_DIRECTORY}"
case "$OUTPUT_DIR" in /*) ;; *) echo "Scratch path must be absolute" >&2; exit 1 ;; esac
mkdir -p "$OUTPUT_DIR/module-cache" "$OUTPUT_DIR/tmp"
export TMPDIR="$OUTPUT_DIR/tmp"
PYTHON="$(command -v python3)"
TARGET="$(uname -m)-apple-macosx15.0"
xcrun swiftc -swift-version 6 -target "$TARGET" -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$REPO_DIR/Sources/EngramVisualizer/Panels/LearnerHealthReader.swift" \
    "$REPO_DIR/Tests/learner_health_ui/LearnerHealthReaderChecks.swift" \
    -o "$OUTPUT_DIR/reader-checks"
"$OUTPUT_DIR/reader-checks" "$REPO_DIR/Tests/learner_health_ui/held-health.json" "$PYTHON" "$OUTPUT_DIR/fixtures"
xcrun swiftc -swift-version 6 -target "$TARGET" -typecheck -module-cache-path "$OUTPUT_DIR/module-cache" \
    "$REPO_DIR/Sources/EngramVisualizer/Panels/LearnerHealthReader.swift" \
    "$REPO_DIR/Sources/EngramVisualizer/Panels/LearnerHealthView.swift"
bash "$REPO_DIR/scripts/package_codex_learner.sh" "$OUTPUT_DIR/package"
cmp "$REPO_DIR/codex/plugins/engram/skills/hook-status/scripts/hook_status.py" "$OUTPUT_DIR/package/hook_status.py"
echo "SwiftUI typecheck and exact bundled-reader comparison passed."

#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 2 ]]; then
    echo "Usage: $0 CORE_PRODUCT_DIRECTORY OUTPUT_DIRECTORY" >&2
    exit 2
fi
test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$test_dir/../.." && pwd)"
core_products="$1"
output_dir="$2"
mkdir -p "$output_dir/module-cache" "$output_dir/tmp"
export TMPDIR="$output_dir/tmp"
export CLANG_MODULE_CACHE_PATH="$output_dir/module-cache"

xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -target "$(uname -m)-apple-macosx15.0" \
    -I "$core_products" -L "$core_products" -lEngramMemoryCore \
    -module-cache-path "$output_dir/module-cache" \
    "$repo_dir/Sources/EngramKit/MemoryOperationCanonicalPayload.swift" \
    "$test_dir/CanonicalPayloadTests.swift" \
    -o "$output_dir/canonical-payload-tests"
reference_digest="$(python3 -B "$test_dir/reference_vector.py")"
"$output_dir/canonical-payload-tests" "$reference_digest"

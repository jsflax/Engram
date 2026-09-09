# macOS performance checks

Run from the repository root on an otherwise idle Mac with a visible, unlocked
desktop. Keep hardware, display refresh rate, window size, camera settings, power
mode, and fixture constant between baseline and candidate. Run benchmarks and
builds serially; competing GPU work invalidates comparisons. Keep the pinned
remote dependencies used by the release build, not local dependency overrides.

## Deterministic renderer profiling

Use a fresh build directory per revision so generated shaders cannot be stale:

```sh
perf_root=$(mktemp -d /private/tmp/engram-macos-perf.XXXXXX)
swift build --scratch-path "$perf_root/build" -c release --product EngramPreview
python3 scripts/profile_macos.py \
  --binary "$perf_root/build/release/EngramPreview" \
  --nodes 4000 --orbit 20 --frames 1800 --warmup 1000 \
  --output "$perf_root/preview-4k" --require-budget
python3 scripts/profile_macos.py \
  --binary "$perf_root/build/release/EngramPreview" \
  --nodes 40000 --orbit 20 --frames 1800 --warmup 1000 \
  --output "$perf_root/preview-40k" --require-budget
```

Each output directory must not already exist. The harness saves `frames.csv`,
`resources.csv`, `app.log`, and `report.json`. It sets `PREVIEW_SEED=42` and
`SWIFT_DETERMINISTIC_HASHING=1`; the preview uses seeded graph generation and
`PREVIEW_AUTO_ORBIT` advances the camera's **target** azimuth every frame. The
default orbit is 20 degrees/second. Repeat with `--scale 0.15` for a close-camera
LOD/edge stress case; use the same scale on both revisions.

SwiftPM copies RealityKit `.metal` sources without building its default library.
The harness compiles a missing `Engram_EngramRealityKit.bundle/default.metallib`
using `xcrun metal`/`metallib` before timing. It requires the actual shader path,
not a fallback-material run. Do not reuse an old generated library after shader
edits. Preview is a synthetic renderer workload, not proof of full-app loading or
menu responsiveness. It does not need a personal database; do not enable its
optional `PREVIEW_USE_LATTICE` mode for these fixtures.

Frame `nodes`/`edges` describe loaded graph inputs, not simultaneous draws.
`vis_edges` is the LOD-selected count. The existing macOS 26 single-row instance
texture caps actual edge instances at 16,384 even when LOD selects 30,000;
keep this same limit on both revisions and do not report it as 30,000 drawn edges.

## Full-app loading from a real database copy

```sh
swift build --scratch-path "$perf_root/build" -c release --product EngramVisualizer
python3 scripts/profile_app_loading.py \
  --binary "$perf_root/build/release/EngramVisualizer" \
  --database /absolute/path/to/source-memory.sqlite \
  --source-root "$PWD" --timeout 120 \
  --output "$perf_root/app-load"
```

The source is opened read-only and copied with SQLite's backup API, including
committed WAL contents. Only the disposable copy is passed to the app. Copied
configuration is normalized to Graph/Force, no hidden projects or relations,
local project policies, no group exposure, and disabled sound/notifications.
The harness compiles the current shader sources before launch and preserves the
copy, logs, raw frames, and a success/failure report for diagnosis.

Readiness means the first **observed, flushed** frame containing every copied
`Memory` row. The report records launch-to-readiness, the first full-node frame,
and scene elapsed time. Launch time includes the 120-frame CSV flush delay and
100 ms polling; it is not exact GPU presentation time. Compare baseline and
candidate with this same protocol. A partial graph is not a successful load.

## Hosted tests and menu interactions

Xcode UI tests need a logged-in, unlocked desktop, visible app windows, available
status bar space, and permission for Xcode/test-runner UI automation. Do not
interpret a locked-screen, inaccessible-status-item, or missing-window failure
as performance data. Resolve dependencies and signing prerequisites first.

```sh
xcodebuild build-for-testing -project Engram.xcodeproj -scheme Engram \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$perf_root/DerivedData" ENABLE_TESTABILITY=YES
xcodebuild test-without-building -project Engram.xcodeproj -scheme Engram \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$perf_root/DerivedData" \
  -parallel-testing-enabled NO \
  -only-testing:EngramUnitTests/PanelPerformanceTests \
  -only-testing:EngramUITests/RealityFrameReportParserTests \
  -only-testing:EngramUITests/MacOSResponsivenessTests \
  -resultBundlePath "$perf_root/panels.xcresult"
```

The pure parser/SQLite-fixture tests can also run without UI automation after
building the target. Select only that class and use a clean environment:

```sh
/usr/bin/env -i /usr/bin/xcrun xctest \
  -XCTest EngramUITests.RealityFrameReportParserTests \
  "$perf_root/DerivedData/Build/Products/Release/EngramUITests-Runner.app/Contents/PlugIns/EngramUITests.xctest"
```

This does not satisfy the interactive UI gate. Avoid passing an inherited
credential environment to diagnostic tools; some error/help paths print it.

For a serial Swift Testing correctness run, use the installed SwiftPM bundle
loader after building the Release tests with `-Xswiftc -enable-testing`; ordinary
Release builds do not permit the existing `@testable` imports. Keep normal
profiling products staged separately before changing build flags. The macOS
test image is a Mach-O bundle,
not a directly executable program. Preserve the normal release selection below;
`--no-parallel` here reaches Swift Testing itself. The SQL-budget tests still run
separately as documented in the release workflow.

```sh
swift build -c release --build-tests -Xswiftc -enable-testing \
  --disable-automatic-resolution --skip-update
perf_developer_dir="$(xcode-select -p)"
perf_swift_bin="$(dirname "$(xcrun --find swiftc)")"
/usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin TMPDIR=/private/tmp \
  DEVELOPER_DIR="$perf_developer_dir" \
  DYLD_FRAMEWORK_PATH="$perf_developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks" \
  "$perf_swift_bin/../libexec/swift/pm/swiftpm-testing-helper" \
  --test-bundle-path "$PWD/.build/arm64-apple-macosx/release/EngramPackageTests.xctest/Contents/MacOS/EngramPackageTests" \
  --testing-library swift-testing --no-parallel \
  --filter 'EngramTests|EngramRealityKitTests|PositionVersionTests' \
  --skip PerfTests --skip keyBERTKeywordExtraction \
  --skip recall_semanticRelevanceOrdering \
  --skip recall_connectedMemory_showsEdgeRelation \
  --skip recall_graphTraversal_relatesToDoesNotLeakViaUnrelatedStructuralEdge \
  --skip recall_statementBudget --skip clusters_statementBudget
```

Check both the complete test count and actual model classifications: an on-device
model availability guard can return without exercising its assertion. Keep prior
parallel failures in the report; a serial pass does not prove their cause.

`MacOSResponsivenessTests` seeds 4,000 deterministic memories by default. Set
`ENGRAM_PERF_NODE_COUNT=40000` in the **test runner's** environment for the 40,000
case. Alternatively set `ENGRAM_PERF_DB_SNAPSHOT=/absolute/path/to/source.sqlite`;
the test backs it up read-only, normalizes copied sync policies, and reads the
actual copied row count. Configure these in the Xcode Test action/test plan or
the generated `.xctestrun` runner environment; do not assume an environment
variable on the `xcodebuild` shell reaches the runner. Use a distinct result
bundle for each run. `RealDBPerfTests` also accepts the snapshot variable; its
legacy diagnostic paths require the `Engram-UITesting` scheme and serial runs.

The menu test attempts its first tab cycle as soon as controls are accessible,
then repeats at full size: Graph, Logs, Settings, Account, the native View menu,
and the status activity feed. App launch and accessibility discovery can outlast
loading, so this sequence alone does not prove interaction during the initial
drain. Tab/feed actions each have five samples; sidebar opening has approximately
two, making its p95 effectively the observed maximum, not a robust distribution. It
keeps frame/panel CSVs, graph/sidebar/feed screenshots, and launch-to-full-node
readiness in the `.xcresult`. Its readiness polling is 20 ms and still includes
CSV flush delay. `PanelPerformanceTests` covers bounded menu snapshots, zero SQL
in the actual timestamp helper, same-count edits/deletes, burst coalescing,
cancellation, irrelevant audit updates, and deferred panel capture during the
initial graph drain.

The separate `testGraphSidebarRetainsOffscreenProjectsAndRelations` UI test
uses 128 generated projects and six relation types. Ordinary wheel scrolling
must reach the last seeded project and relation, then return to the first
project. It never clicks visibility toggles and is not latency evidence.

Panel latency is an event-timestamp-to-`NSView.draw` **proxy**, not compositor or
display presentation. The cached status panel uses its owning AppKit window's
actual visibility transitions, not SwiftUI `onAppear`, to restart observation
and measure each opening. It preserves cached rows while hidden and stops its
subscription on hide/detach. Recording still relies on `NSApp.currentEvent`
being the opening input; inspect questionable samples. Callback-only timings
cannot satisfy the gate. Native View menu timings include XCTest accessibility
and click overhead and are reported separately, not asserted as sub-100 ms
presentation measurements.

When panel recording is enabled, `<panel CSV>.phases.csv` adds a separate
diagnostic breakdown: event-to-recorder-begin, begin-to-mutation-return,
mutation-return-to-draw, and begin-to-draw. The last is an overlapping aggregate,
not an additional term to sum. The tab recorder begins after its existing live
guard; it is not exact button-action entry. Non-mutation actions leave both
mutation fields empty. This sidecar does not change the original three-column
response CSV, event timestamp, or 100 ms gate. XCTest attachments retain it.

## Isolation and sensitive artifacts

`ENGRAM_PERF_ISOLATED=1` disables normal account/sync/updater/CLI-install service
startup; hosted tests also select isolation automatically. A missing explicit
database path gets a temporary database. Always launch against a generated
fixture or backup, never point `CLAUDE_MEMORY_DB` at the live source. Isolation
is not read-only mode: the app can mutate its selected database. Hidden-project
and relation resets are limited to resolved temporary fixture paths, not
symlinks to real databases.

Harness sleep assertions are scoped to their child processes; they do not change
persistent power settings. UI tests terminate their app and remove their own
temporary fixture in teardown. Standalone harness outputs are retained: copies,
screenshots, and logs may contain private memories or account metadata. Keep
them local; publish aggregate timings only. Review and remove only the exact
generated output directory when finished.

## Thirty-minute memory soak

```sh
python3 scripts/profile_macos.py \
  --binary "$perf_root/build/release/EngramPreview" \
  --nodes 40000 --orbit 20 --seconds 1800 --warmup 1000 \
  --output "$perf_root/soak-40k" --require-budget
```

RSS/CPU are sampled once per second. The stability ratio is median RSS in the
last five minutes divided by median RSS during minutes 5–10; require at most
`1.10` after a full 30-minute run. A short run without `soak_memory_stable` is not
soak evidence, even if `--require-budget` exits successfully. Retain the raw
resource series to inspect sustained growth rather than just endpoint noise.

## Release gates and report interpretation

- Current named frame schema: all 21 columns, unique names, finite nonnegative
  values, and increasing frame IDs. Missing/obsolete/empty data fails closed.
  After the configured active warmup frames (120 by default; 1,000 above to
  include simulation settling), require at least 100 active samples.
- Renderer `dt_ms` p95 must be at most **33 ms**. `total_ms` is measured scene CPU
  update work, not GPU execution time; warmed maximum must be at most **100 ms**.
- **Cold/startup CPU work must also stay at or below 100 ms.** Inspect
  `startup_update_max_ms` and raw loading frames. The automatic budget flag
  also requires `all_updates_under_100ms`, covering every recorded scene CPU
  update including startup: warmup cannot waive a cold stall. Hold the release
  until both windows pass. This does not time work outside the scene update;
  the full-app UI checks remain necessary.
- Sidebar/feed first-draw proxy p95 must be at most **100 ms**, with real event
  origins. Check native menu behavior separately and inspect retained visuals.
- Full-app loading must reach the complete fixture without regressing the
  comparable baseline. Investigate load maxima separately from steady orbit.
- Complete the 30-minute RSS gate above, correctness regressions, and visual
  checks for labels, edges, project/galaxy colors, LOD transitions, and deletion.
  A faster run with missing content is a failure.

Re-analyze saved renderer data with
`python3 scripts/profile_macos.py --analyze /absolute/path/to/frames.csv`.
Run harness parser regressions with
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p 'test_profile*.py'`.
Record commit, resolved dependencies, hardware/display settings, fixture size,
camera scale, cold/warmed timing distributions, readiness, and RSS ratio beside
the retained artifacts before tagging a release. This guide contains no claimed
benchmark results.

#!/usr/bin/env python3
"""Measure isolated full-app graph loading from a disposable SQLite backup.

Build EngramVisualizer in Release first. Example:
  python3 scripts/profile_app_loading.py --binary .build/release/EngramVisualizer \
      --database /tmp/memory-source.sqlite --output /tmp/engram-app-load-current

Readiness is the first observed, fully flushed current-format frame whose graph
contains every source Memory row. Wall time includes the app's 120-frame CSV
flush delay and polling (100 ms); it is NOT an exact GPU-presentation timestamp.
The source database is opened read-only and is never passed to the app.
"""

import argparse
from contextlib import closing
import csv
import json
import math
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import time


REQUIRED_COLUMNS = {
    "frame", "dt_ms", "tick_ms", "lod_ms", "node_ms", "edge_ms", "label_ms",
    "commit_ms", "nebula_ms", "galaxy_titles_ms", "mascot_ms", "flow_ms",
    "lights_ms", "audio_ms", "total_ms", "nodes", "edges", "vis_edges",
    "near", "mid", "far",
}


class FrameReader:
    """Read only complete appended records; a concurrent flush may end mid-row."""

    def __init__(self, path):
        self.path = path
        self.offset = 0
        self.pending = ""
        self.columns = None
        self.frames = []

    def poll(self):
        if not self.path.exists():
            return []
        with self.path.open() as source:
            source.seek(self.offset)
            self.pending += source.read()
            self.offset = source.tell()
        lines = self.pending.split("\n")
        self.pending = lines.pop()
        appended = []
        for line in lines:
            if not line.strip() or line.startswith("#"):
                continue
            fields = next(csv.reader([line]))
            if self.columns is None:
                if len(fields) != len(set(fields)) or not REQUIRED_COLUMNS.issubset(fields):
                    raise ValueError("Missing current named RealityKit timing columns")
                self.columns = fields
                continue
            if len(fields) != len(self.columns):
                raise ValueError("Malformed complete frame timing row")
            values = {key: float(value) for key, value in zip(self.columns, fields)}
            if any(not math.isfinite(value) or value < 0 for value in values.values()):
                raise ValueError("Invalid frame timing value")
            if self.frames and values["frame"] <= self.frames[-1]["frame"]:
                raise ValueError("Frame numbers must increase within one app run")
            self.frames.append(values)
            appended.append(values)
        return appended


def prepare_fixture(source, destination):
    # Backup gives a consistent snapshot, including committed WAL contents.
    # The destination is inside a newly created output directory, never a link.
    with closing(sqlite3.connect(source.as_uri() + "?mode=ro", uri=True)) as original:
        with closing(sqlite3.connect(destination)) as fixture:
            original.backup(fixture)
            total, identified, unique = fixture.execute(
                "SELECT count(*), count(globalId), count(DISTINCT globalId) FROM Memory"
            ).fetchone()
            if total <= 0 or total != identified or total != unique:
                raise ValueError("Loading fixture needs nonempty, uniquely identified Memory rows")
            # Lattice audit triggers use this connection-local function. Config
            # normalization is harness-only and must not synthesize sync events.
            fixture.create_function("sync_disabled", 0, lambda: 1)
            fixture.execute(
                "UPDATE VisualizerConfig SET selectedTab = 'Graph', layoutMode = 'Force', "
                "hiddenProjects = '[]', hiddenRelations = '[]', "
                "soundEnabled = 0, notificationsEnabled = 0"
            )
            # Isolated runs have no synced/group galaxies. Registry partition
            # filters still read SyncConfig, so every copied project must be
            # local or some rows would be assigned to a nonexistent galaxy.
            fixture.execute("UPDATE SyncConfig SET policy = 'local', exposedTeams = '[]'")
            fixture.commit()
            configuration = fixture.execute(
                "SELECT selectedTab, layoutMode, hiddenProjects, hiddenRelations, "
                "soundEnabled, notificationsEnabled, showMascots FROM VisualizerConfig"
            ).fetchall()
    return total, configuration


def prepare_shaders(binary, source_root, output):
    # SwiftPM only copies these sources; absent metallib silently changes the
    # visuals to fallback materials. Compile this revision before starting time.
    bundle = binary.parent / "Engram_EngramRealityKit.bundle"
    if not bundle.is_dir():
        raise ValueError("Expected the executable's sibling SwiftPM RealityKit resource bundle")
    if source_root is None:
        source_root = next((parent for parent in binary.parents
                            if (parent / "Package.swift").is_file()), None)
    if source_root is None:
        raise ValueError("Cannot locate shader sources; pass --source-root")
    shaders = sorted((source_root / "Sources/EngramRealityKit/Shaders").glob("*.metal"))
    if not shaders:
        raise ValueError("RealityKit shader sources not found")
    with (output / "shaders.log").open("w") as log:
        with tempfile.TemporaryDirectory(prefix="engram-app-load-metal-") as temporary:
            objects = []
            for source in shaders:
                target = Path(temporary) / (source.stem + ".air")
                subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-c", str(source),
                                "-o", str(target)], stdout=log, stderr=log, check=True)
                objects.append(str(target))
            library = Path(temporary) / "default.metallib"
            subprocess.run(["xcrun", "-sdk", "macosx", "metallib", *objects, "-o", str(library)],
                           stdout=log, stderr=log, check=True)
            shutil.copy2(library, bundle / "default.metallib")


def stop_child(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def profile(args):
    binary = args.binary.resolve(strict=True)
    source = args.database.resolve(strict=True)
    if binary.name != "EngramVisualizer" or not os.access(binary, os.X_OK):
        raise ValueError("--binary must be a built, executable EngramVisualizer")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixture = output / "memory.sqlite"
    frame_path = output / "frames.csv"
    result = {
        "status": "failed", "binary": str(binary), "source_database": str(source),
        "fixture_database": str(fixture), "frames_csv": str(frame_path),
        "timeout_seconds": args.timeout, "poll_seconds": 0.1,
        "metric": "launch to first observed flushed frame containing all Memory rows",
        "includes_csv_flush_delay": True, "csv_flush_frames": 120,
    }
    process = None
    wake_assertion = None
    started = None
    reader = FrameReader(frame_path)
    try:
        expected, configuration = prepare_fixture(source, fixture)
        result.update(expected_nodes=expected, fixture_configuration=configuration)
        prepare_shaders(binary, args.source_root.resolve() if args.source_root else None, output)
        environment = dict(os.environ)
        for key in ("ENGRAM_TEST_INSERT_DELAY", "ENGRAM_FORCE_SOUND", "PREVIEW_NODE_COUNT",
                    "PREVIEW_AUTO_ORBIT", "PREVIEW_ORBIT_SCALE"):
            environment.pop(key, None)
        environment.update(ENGRAM_PERF_ISOLATED="1", CLAUDE_MEMORY_DB=str(fixture),
                           ENGRAM_FRAME_STATS=str(frame_path), SWIFT_DETERMINISTIC_HASHING="1",
                           PREVIEW_EXIT_AFTER_FRAMES=str(2**62))
        with (output / "app.log").open("w") as log:
            started = time.monotonic()
            process = subprocess.Popen([str(binary)], env=environment, stdout=log, stderr=log)
            result["pid"] = process.pid
            # Only this child gets temporary idle/display assertions. The app's
            # opt-in ProcessInfo activity separately prevents App Nap.
            wake_assertion = subprocess.Popen(["/usr/bin/caffeinate", "-di", "-w", str(process.pid)])
            while True:
                for row in reader.poll():
                    if row["nodes"] == expected:
                        result.update(status="ready", graph_ready_observed_seconds=time.monotonic() - started,
                                      first_full_graph_frame=row,
                                      scene_elapsed_to_full_graph_ms=sum(
                                          frame["dt_ms"] for frame in reader.frames
                                          if frame["frame"] <= row["frame"]))
                        break
                if result["status"] == "ready":
                    break
                if process.poll() is not None:
                    raise RuntimeError(f"App exited {process.returncode} before the full graph was observed")
                if time.monotonic() - started >= args.timeout:
                    raise TimeoutError(f"Full graph not observed within {args.timeout:g} seconds")
                time.sleep(0.1)
    except Exception as error:
        result["error"] = f"{type(error).__name__}: {error}"
    finally:
        stop_child(process)
        stop_child(wake_assertion)
        if started is not None:
            result["elapsed_seconds"] = time.monotonic() - started
        if process is not None:
            result["app_exit_code"] = process.returncode
        result["flushed_frames"] = len(reader.frames)
        result["max_observed_nodes"] = int(max((row["nodes"] for row in reader.frames), default=0))
        (output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    result = profile(args)
    print(json.dumps(result, indent=2))
    if result["status"] != "ready":
        raise SystemExit(1)


if __name__ == "__main__":
    main()

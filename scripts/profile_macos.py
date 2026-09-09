#!/usr/bin/env python3
"""Profile an isolated EngramPreview Release binary; save raw data and a JSON report.

Example: python3 scripts/profile_macos.py --binary .build/release/EngramPreview \
    --nodes 40000 --orbit 20 --output /tmp/engram-profile-40k
Use --seconds 1800 for a memory soak, or --analyze frames.csv for existing data.
"""

import argparse
import csv
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time


REQUIRED_COLUMNS = {
    "frame", "dt_ms", "tick_ms", "lod_ms", "node_ms", "edge_ms", "label_ms",
    "commit_ms", "nebula_ms", "galaxy_titles_ms", "mascot_ms", "flow_ms",
    "lights_ms", "audio_ms", "total_ms", "nodes", "edges", "vis_edges",
    "near", "mid", "far",
}


def distribution(values):
    ordered = sorted(values)
    if not ordered:
        raise ValueError("No samples")
    return {
        "p50": ordered[min(int(len(ordered) * 0.50), len(ordered) - 1)],
        "p95": ordered[min(int(len(ordered) * 0.95), len(ordered) - 1)],
        "p99": ordered[min(int(len(ordered) * 0.99), len(ordered) - 1)],
        "max": ordered[-1],
        "mean": statistics.mean(ordered),
    }


def analyze(path, warmup=120):
    with Path(path).open() as source:
        reader = csv.DictReader(line for line in source if line.strip() and not line.startswith("#"))
        fields = reader.fieldnames or []
        if len(fields) != len(set(fields)) or not REQUIRED_COLUMNS.issubset(fields):
            raise ValueError("Missing current RealityKit timing columns")
        frames = []
        for row in reader:
            if None in row or any(value is None for value in row.values()):
                raise ValueError("Malformed timing row")
            values = {key: float(value) for key, value in row.items()}
            if any(not math.isfinite(value) or value < 0 for value in values.values()):
                raise ValueError("Invalid timing value")
            if not values["frame"].is_integer():
                raise ValueError("Frame numbers must be integers")
            if frames and values["frame"] <= frames[-1]["frame"]:
                raise ValueError("Frame numbers must increase within one preview run")
            frames.append(values)
    active = [row for row in frames if row["nodes"] > 0 and row["dt_ms"] > 0][warmup:]
    if len(active) < 100:
        raise ValueError(f"Need at least 100 rendered samples after warmup; got {len(active)}")
    phases = {key: distribution([row[key] for row in active])
              for key in active[0] if key.endswith("_ms")}
    return {
        "frames": len(active), "recorded_frames": len(frames), "warmup_frames": warmup,
        "nodes": int(max(row["nodes"] for row in active)),
        "edges": int(max(row["edges"] for row in active)),
        "timings_ms": phases,
        "frame_p95_under_33ms": phases["dt_ms"]["p95"] <= 33,
        "update_max_under_100ms": phases["total_ms"]["max"] <= 100,
        "all_updates_under_100ms": max(row["total_ms"] for row in frames) <= 100,
        "startup_update_max_ms": max(row["total_ms"] for row in frames),
    }


def profile(args):
    # SwiftPM copies .metal sources but does not compile RealityKit's default
    # library. Without this, profiling silently measures fallback materials.
    bundle = args.binary.resolve().parent / "Engram_EngramRealityKit.bundle"
    library = bundle / "default.metallib"
    if not library.exists():
        if not bundle.is_dir():
            raise ValueError("Expected a SwiftPM EngramPreview binary and its resource bundle")
        shaders = Path(__file__).resolve().parent.parent / "Sources/EngramRealityKit/Shaders"
        with tempfile.TemporaryDirectory(prefix="engram-profile-metal-") as temporary:
            objects = []
            for source in sorted(shaders.glob("*.metal")):
                target = Path(temporary) / (source.stem + ".air")
                subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-c", str(source), "-o", str(target)], check=True)
                objects.append(str(target))
            if not objects:
                raise ValueError("RealityKit shader sources not found")
            subprocess.run(["xcrun", "-sdk", "macosx", "metallib", *objects, "-o", str(library)], check=True)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    frame_path = output / "frames.csv"
    environment = dict(os.environ, PREVIEW_NODE_COUNT=str(args.nodes), PREVIEW_SEED="42",
                       SWIFT_DETERMINISTIC_HASHING="1", PREVIEW_AUTO_ORBIT=str(args.orbit),
                       PREVIEW_ORBIT_SCALE=str(args.scale), ENGRAM_FRAME_STATS=str(frame_path),
                       PREVIEW_EXIT_AFTER_FRAMES=str(2**62 if args.seconds else args.frames))
    resources = []
    started = time.monotonic()
    with (output / "app.log").open("w") as log, (output / "resources.csv").open("w") as resource_log:
        resource_writer = csv.DictWriter(resource_log, fieldnames=["seconds", "rss_mb", "cpu_percent"])
        resource_writer.writeheader()
        resource_log.flush()
        process = subprocess.Popen([str(args.binary.resolve())], env=environment, stdout=log, stderr=log)
        # Scope the display/idle-sleep assertion to this child, never change
        # the user's persistent power settings. Preview separately holds an
        # opt-in ProcessInfo activity to prevent App Nap while profiling.
        wake_assertion = subprocess.Popen(["/usr/bin/caffeinate", "-di", "-w", str(process.pid)])
        try:
            while process.poll() is None:
                elapsed = time.monotonic() - started
                if elapsed > (args.seconds or args.timeout):
                    process.terminate()
                    process.wait(timeout=10)
                    if not args.seconds:
                        raise TimeoutError("Preview did not finish within its timeout")
                    break
                sample = subprocess.run(["/bin/ps", "-o", "rss=,pcpu=", "-p", str(process.pid)],
                                        capture_output=True, text=True, check=False).stdout.split()
                if len(sample) == 2:
                    resource = {"seconds": elapsed, "rss_mb": int(sample[0]) / 1024,
                                "cpu_percent": float(sample[1])}
                    resources.append(resource)
                    resource_writer.writerow(resource)
                    # Preserve soak evidence even if the harness is interrupted.
                    resource_log.flush()
                time.sleep(1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            wake_assertion.terminate()
            wake_assertion.wait(timeout=10)
    elapsed = time.monotonic() - started
    if process.returncode != 0 and not (args.seconds and elapsed >= args.seconds and process.returncode == -15):
        raise RuntimeError(f"Preview exited {process.returncode}; see {output / 'app.log'}")
    result = analyze(frame_path, args.warmup)
    if result["nodes"] != args.nodes:
        raise ValueError("Preview did not render the requested node count")
    if args.seconds and elapsed < args.seconds:
        raise ValueError("Preview exited before the requested soak duration")
    # Empty startup frames still count toward the application's exit hook.
    # Only percentile analysis excludes them; using its active count here
    # incorrectly reports a completed full-app load as a premature exit.
    if not args.seconds and result["recorded_frames"] < args.frames - 2:
        raise ValueError("Preview exited before the requested frame count")
    result.update(binary=str(args.binary.resolve()), seed=42, orbit=args.orbit,
                  orbit_scale=args.scale, elapsed_seconds=elapsed)
    if resources:
        result["rss_mb"] = distribution([row["rss_mb"] for row in resources])
        result["cpu_percent"] = distribution([row["cpu_percent"] for row in resources])
        # Compare five-minute windows after a five-minute warmup for a 30-minute soak.
        first = [row["rss_mb"] for row in resources if 300 <= row["seconds"] < 600]
        last = [row["rss_mb"] for row in resources if row["seconds"] >= result["elapsed_seconds"] - 300]
        if first and last and result["elapsed_seconds"] >= 1800:
            ratio = statistics.median(last) / statistics.median(first)
            result["soak_rss_ratio"] = ratio
            result["soak_memory_stable"] = ratio <= 1.10
    (output / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--analyze", type=Path)
    parser.add_argument("--nodes", type=int, default=4000)
    parser.add_argument("--orbit", type=float, default=20)
    parser.add_argument("--scale", type=float, default=1)
    parser.add_argument("--frames", type=int, default=900)
    parser.add_argument("--warmup", type=int, default=120)
    parser.add_argument("--seconds", type=int)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--require-budget", action="store_true")
    args = parser.parse_args()
    if not args.analyze and (not args.binary or not args.output):
        parser.error("--binary and --output are required when launching")
    result = analyze(args.analyze, args.warmup) if args.analyze else profile(args)
    print(json.dumps(result, indent=2))
    if args.require_budget and not (result["frame_p95_under_33ms"] and result["update_max_under_100ms"]
                                    and result["all_updates_under_100ms"]
                                    and result.get("soak_memory_stable", True)):
        raise SystemExit("Performance budget exceeded")


if __name__ == "__main__":
    main()

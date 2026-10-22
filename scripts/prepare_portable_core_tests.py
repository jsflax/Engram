#!/usr/bin/env python3
"""Stage the exact portable core and tests without Engram's Apple-only graph."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil


def prepare(repository: Path, destination: Path, source_sha: str | None = None) -> dict:
    repository = repository.resolve(strict=True)
    if source_sha is not None and re.fullmatch(r"[0-9a-f]{40}", source_sha) is None:
        raise ValueError("Expected a full Git source SHA")
    # A fresh destination prevents stale source or test files from participating.
    destination.mkdir(parents=True, exist_ok=False)
    hashes = {}
    for relative in ("Sources/EngramMemoryCore", "Tests/EngramMemoryCoreTests", "Tests/Fixtures/ProcessGuard"):
        checked = repository
        for part in Path(relative).parts:
            checked /= part
            if checked.is_symlink() or not checked.is_dir():
                raise ValueError(f"Portable source root must be a real directory: {checked}")
        source = repository / relative
        files = sorted(source.rglob("*"))
        if not any(path.suffix == ".swift" for path in files):
            raise ValueError(f"No Swift files in {relative}")
        for path in files:
            if path.is_symlink():
                raise ValueError(f"Symlink in portable sources: {path}")
            if path.is_file():
                name = path.relative_to(repository).as_posix()
                target = destination / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                    raise ValueError(f"Copy mismatch: {name}")
                hashes[name] = digest
    manifest = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "EngramPortableQualification",
    products: [.library(name: "EngramMemoryCore", targets: ["EngramMemoryCore"])],
    targets: [
        .target(name: "EngramMemoryCore"),
        .executableTarget(name: "EngramProcessGuardFixture", dependencies: ["EngramMemoryCore"],
                          path: "Tests/Fixtures/ProcessGuard"),
        .testTarget(name: "EngramMemoryCoreTests", dependencies: ["EngramMemoryCore", "EngramProcessGuardFixture"]),
    ]
)
'''
    (destination / "Package.swift").write_text(manifest)
    report = {"source_root": str(repository), "source_sha": source_sha, "destination": str(destination),
              "files_sha256": hashes,
              "manifest_sha256": hashlib.sha256(manifest.encode()).hexdigest()}
    (destination / "source-identity.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--source-sha", help="Git SHA verified by the checkout/archive caller")
    arguments = parser.parse_args()
    report = prepare(arguments.repository, arguments.destination, arguments.source_sha)
    print(f"Staged {len(report['files_sha256'])} exact portable source/test files")

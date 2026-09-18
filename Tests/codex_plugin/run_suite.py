#!/usr/bin/env python3
"""Run the assembled source plugin regressions; no native server/provider use."""
import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

from suite_support import PLUGIN_ROOT, TEST_ROOT


MODULES = (
    "test_frontier", "test_router", "test_host", "test_receipts",
    "test_budget_guidance", "test_lock_inheritance", "test_hook_parity",
    "test_hook_status", "test_bootstrap", "test_entry_integration",
    "test_memory_policy",
)

def run_module(name):
    module = importlib.import_module(name)
    suite = unittest.defaultTestLoader.loadTestsFromModule(module)
    output = io.StringIO()
    result = unittest.TextTestRunner(stream=output, verbosity=2).run(suite)
    row = {"module": name, "tests": result.testsRun, "failures": len(result.failures),
           "errors": len(result.errors), "skipped": len(result.skipped)}
    if not result.wasSuccessful():
        print(output.getvalue()[-12000:], flush=True)
    print(json.dumps(row), flush=True)
    return int(not result.wasSuccessful())


def source_hashes():
    return {str(path.relative_to(PLUGIN_ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(PLUGIN_ROOT.rglob("*"))
            if path.is_file() and path.suffix in {".py", ".json", ".md", ".yaml"}}


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--module" and sys.argv[2] in MODULES:
        return run_module(sys.argv[2])
    if len(sys.argv) != 1:
        raise SystemExit("Usage: run_suite.py")
    before = source_hashes()
    results = []
    for name in MODULES:
        # The original tests use overlapping module aliases. Fresh processes
        # guarantee each group imports the actual repository package independently.
        child = subprocess.run(
            [sys.executable, "-B", str(Path(__file__).resolve()), "--module", name],
            cwd=TEST_ROOT, env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
            capture_output=True, text=True, timeout=180)
        try:
            row = json.loads(child.stdout.splitlines()[-1])
            if row["module"] != name or (child.returncode and not (row["failures"] or row["errors"])):
                raise ValueError("inconsistent child result")
        except (ValueError, IndexError, KeyError):
            row = {"module": name, "tests": 0, "failures": 0, "errors": 1, "skipped": 0}
        results.append(row)
        print(json.dumps(row), flush=True)
        if child.returncode:
            print((child.stdout + child.stderr)[-12000:], flush=True)
    after = source_hashes()
    report = {
        "plugin_root": str(PLUGIN_ROOT),
        "plugin_version": json.loads((PLUGIN_ROOT / ".codex-plugin/plugin.json").read_text())["version"],
        "tests": sum(row["tests"] for row in results),
        "failures": sum(row["failures"] for row in results),
        "errors": sum(row["errors"] for row in results),
        "modules": results,
        "source_sha256": after,
        "source_unchanged_during_run": before == after,
        "module_isolation": "separate Python subprocess per group",
    }
    (TEST_ROOT / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: report[key] for key in ("plugin_version", "tests", "failures", "errors")}))
    return int(bool(report["failures"] or report["errors"] or before != after))


if __name__ == "__main__":
    raise SystemExit(main())
